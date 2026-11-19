import ReplicoOptimizations
import Foundation
import Logging
import MCP
import NIOCore
import NIOPosix
import SystemPackage
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Owns one event-driven pipe channel until disconnect has drained its task.
actor StandardIOTransport: Transport {
    private struct Connection: Sendable {
        let channel: any Channel
        let task: Task<Void, Never>
        let pipe: AtomicPipeWriter?
        var queuedWrites = 0
    }

    private enum State {
        case idle
        case starting(Task<Void, Never>, CheckedContinuation<Void, any Error>)
        case connected(Connection)
        case stopping(Task<Void, Never>)
        case stopped
    }

    nonisolated let logger = Logger(label: "ReplicoMCP.stdio", factory: { _ in SwiftLogNoOpLogHandler() })
    private nonisolated let eventLoop: any EventLoop
    private let server: ReplicoServer?

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        eventLoop.executor.asUnownedSerialExecutor()
    }

    private let input: FileHandle
    private let output: FileHandle
    private let maximumMessageBytes: Int
    private let messages: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private var state: State = .idle

    init(
        input: FileHandle = .standardInput, output: FileHandle = .standardOutput,
        maximumMessageBytes: Int = 64 * 1_024 * 1_024, server: ReplicoServer? = nil
    ) {
        precondition(maximumMessageBytes > 0)
        self.server = server
        eventLoop = server?.eventLoop ?? MultiThreadedEventLoopGroup.singleton.next()
        self.input = input
        self.output = output
        self.maximumMessageBytes = maximumMessageBytes
        let stream = AsyncThrowingStream<Data, any Error>.makeStream()
        messages = stream.stream
        continuation = stream.continuation
    }

    func connect() async throws {
        if case .connected = state {
            return
        }
        guard case .idle = state else {
            throw MCPError.connectionClosed
        }
        try await withCheckedThrowingContinuation { ready in
            let task = Task {
                await run()
            }
            state = .starting(task, ready)
        }
    }

    func receive() -> AsyncThrowingStream<Data, any Error> {
        messages
    }

    private enum Outgoing {
        case message(Data)
        case framed(ByteBuffer, after: ByteBuffer?)
    }

    func send(_ message: Data) async throws {
        try await send(.message(message))
    }

    func send(_ body: ByteBuffer, after header: ByteBuffer?) async throws {
        try await send(.framed(body, after: header))
    }

    private func send(_ outgoing: Outgoing) async throws {
        try await withTaskCancellationHandler {
            guard case .connected(var connection) = state else {
                throw MCPError.connectionClosed
            }
            try Task.checkCancellation()
            let header: ByteBuffer?
            let bytes: ByteBuffer
            switch outgoing {
            case .message(let message):
                var buffer = ByteBufferAllocator().buffer(capacity: message.count + 1)
                buffer.writeBytes(message)
                buffer.writeInteger(UInt8(10))
                bytes = buffer
                header = nil
            case .framed(let body, let first):
                bytes = body
                header = first
            }
            if header == nil, connection.queuedWrites == 0, try connection.pipe?.writeIfPossible(bytes) == true {
                return
            }
            connection.queuedWrites += 1
            state = .connected(connection)
            defer {
                if case .connected(var current) = state {
                    current.queuedWrites -= 1
                    state = .connected(current)
                }
            }
            try await withCheckedThrowingContinuation { (sent: CheckedContinuation<Void, any Error>) in
                guard case .connected = state else {
                    sent.resume(throwing: MCPError.connectionClosed)
                    return
                }
                // Register completion before yielding the actor to a possible disconnect.
                if let header {
                    // This actor runs on the pipe's event loop. No other frame can enter between the two writes.
                    let first = connection.channel.write(header)
                    let last = connection.channel.writeAndFlush(bytes)
                    first.and(last).map { _ in () }.whenComplete { sent.resume(with: $0) }
                } else {
                    connection.channel.writeAndFlush(bytes).whenComplete { sent.resume(with: $0) }
                }
            }
        } onCancel: {
            Task { await self.disconnect() }
        }
    }

    func disconnect() async {
        continuation.finish()
        let task: Task<Void, Never>
        switch state {
        case .idle:
            state = .stopped
            return
        case .starting(let owner, let ready):
            task = owner
            state = .stopping(owner)
            ready.resume(throwing: CancellationError())
            owner.cancel()
        case .connected(let connection):
            task = connection.task
            state = .stopping(task)
            // The owner already awaits closeFuture and drains the event loop.
            connection.channel.close(promise: nil)
        case .stopping(let owner):
            task = owner
        case .stopped:
            return
        }
        await task.value
    }

    private func run() async {
        do {
            let channel = try await openChannel()
            guard case .starting(let task, let ready) = state else {
                try? await channel.close().get()
                throw CancellationError()
            }
            state = .connected(Connection(channel: channel, task: task, pipe: AtomicPipeWriter(output)))
            ready.resume()
            // Input EOF preserves output until the server finishes admitted messages.
            try await channel.closeFuture.get()
        } catch {
            if case .starting(let task, let ready) = state {
                state = .stopping(task)
                ready.resume(throwing: error)
            }
            continuation.finish(throwing: error)
        }
        if case .connected(let connection) = state {
            state = .stopping(connection.task)
        }
        state = .stopped
    }

    private func openChannel() async throws -> any Channel {
        let inputCopy = try duplicate(input)
        let outputCopy: SystemPackage.FileDescriptor
        do {
            outputCopy = try duplicate(output)
        } catch {
            try? inputCopy.close()
            throw error
        }
        let server = self.server
        let limit = maximumMessageBytes
        let continuation = self.continuation
        do {
            return try await NIOPipeBootstrap(group: eventLoop)
                .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .takingOwnershipOfDescriptors(input: inputCopy.rawValue, output: outputCopy.rawValue) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(
                            ByteToMessageHandler(
                                StandardIOFrameDecoder(maximumMessageBytes: limit), maximumBufferSize: limit
                            ))
                        try channel.pipeline.syncOperations.addHandler(
                            StandardIOReceiver(continuation: continuation, server: server, transport: self))
                        return channel
                    }
                }
        } catch {
            try? inputCopy.close()
            try? outputCopy.close()
            throw error
        }
    }

    private func duplicate(_ handle: FileHandle) throws -> SystemPackage.FileDescriptor {
        let copy = fcntl(handle.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard copy >= 0 else {
            throw Errno(rawValue: errno)
        }
        return SystemPackage.FileDescriptor(rawValue: copy)
    }
}
