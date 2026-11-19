import Foundation
import Logging
import MCP

/// A finite input stream that closes independently of the server's request tasks.
actor EndingTransport: Transport {
    private enum State {
        case idle([Data])
        case connected([Data])
        case disconnected
    }

    nonisolated let logger = Logger(label: "ReplicoMCPTests.EndingTransport")
    private var state: State
    private var sent: [Data] = []

    init(messages: [Data]) {
        state = .idle(messages)
    }

    func connect() async throws {
        if case .idle(let messages) = state {
            state = .connected(messages)
        }
    }

    func disconnect() async {
        state = .disconnected
    }

    func send(_ data: Data) async throws {
        sent.append(data)
    }

    func receive() -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream(unfolding: {
            await self.nextMessage()
        })
    }

    func sentMessages() -> [Data] {
        sent
    }

    private func nextMessage() -> Data? {
        guard case .connected(var messages) = state else {
            return nil
        }
        guard !messages.isEmpty else {
            state = .disconnected
            return nil
        }
        let message = messages.removeFirst()
        state = .connected(messages)
        return message
    }
}
