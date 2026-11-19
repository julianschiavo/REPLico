import ReplicoCore
@testable import ReplicoMCP
import ReplicoOptimizations
import Foundation
import MCP
import NIOCore
import Testing

struct StandardIOTransportTests {
    enum Interruption: CaseIterable, Sendable {
        case cancelWrite
        case disconnect
    }

    @Test
    func pipelinedToolCallsObserveInitializationAndUseTheRegisteredTool() async throws {
        let requests = Pipe()
        let responses = Pipe()
        defer {
            for pipe in [requests, responses] {
                try? pipe.fileHandleForReading.close()
                try? pipe.fileHandleForWriting.close()
            }
        }
        let session = try REPLSession(configuration: REPLConfiguration(nodeExecutable: URL(filePath: "/usr/bin/false")))
        let server = try ReplicoServer(session: session, tools: [MultiplyTool()], environment: [:])
        let transport = StandardIOTransport(
            input: requests.fileHandleForReading, output: responses.fileHandleForWriting, server: server)
        let client = StandardIOTransport(input: responses.fileHandleForReading, output: requests.fileHandleForWriting)
        let serving = Task {
            try await server.run(over: transport)
        }
        do {
            try await client.connect()
            var replies = await client.receive().makeAsyncIterator()
            let parameters = #"{"name":"multiply","arguments":{"value":6,"factor":7},"_meta":{"label":"pipe"}}"#
            func multiply(_ id: Int) -> String {
                #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":\#(parameters)}"#
            }
            let pipeline = [
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"Example","version":"1"},"capabilities":{}}}"#,
                multiply(2),
                #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                multiply(3),
            ]
            try await client.send(Data(pipeline.joined(separator: "\n").utf8))
            for id in 1...4 {
                if id == 4 {
                    // This call arrives after the input backlog has drained.
                    try await client.send(Data(multiply(id).utf8))
                }
                let data = try #require(try await replies.next())
                let reply = try JSONDecoder().decode(JSONValue.self, from: data)
                #expect(reply["id"] == .integer(Int64(id)))
                switch id {
                case 1:
                    #expect(reply["result"]?["protocolVersion"] == .string("2025-11-25"))
                case 2:
                    #expect(reply["error"]?["code"] == .integer(-32600))
                default:
                    #expect(reply["result"]?["structuredContent"]?["value"] == .integer(42))
                }
            }
            await client.disconnect()
            try requests.fileHandleForWriting.close()
            try await serving.value
        } catch {
            serving.cancel()
            await client.disconnect()
            try? requests.fileHandleForWriting.close()
            try? await serving.value
            throw error
        }
    }

    @Test(arguments: Interruption.allCases)
    func interruptingABackpressuredSendDrainsItsWrite(_ interruption: Interruption) async throws {
        let requests = Pipe()
        let responses = Pipe()
        defer {
            for pipe in [requests, responses] {
                try? pipe.fileHandleForReading.close()
                try? pipe.fileHandleForWriting.close()
            }
        }
        let sender = StandardIOTransport(input: responses.fileHandleForReading, output: requests.fileHandleForWriting)
        let receiver = StandardIOTransport(
            input: requests.fileHandleForReading, output: responses.fileHandleForWriting, maximumMessageBytes: 1
        )
        do {
            try await sender.connect()
            try await receiver.connect()
            let sending = Task {
                try await sender.send(Data(repeating: 120, count: 1_048_576))
            }
            // Rejection acknowledges partial receipt while the unread remainder backpressures the sender.
            await #expect(throws: MCPError.self) {
                var messages = await receiver.receive().makeAsyncIterator()
                _ = try await messages.next()
            }
            switch interruption {
            case .cancelWrite:
                sending.cancel()
            case .disconnect:
                await sender.disconnect()
            }
            do {
                try await sending.value
                Issue.record("Expected the blocked write to end with an error.")
            } catch {
                #expect(sending.isCancelled == (interruption == .cancelWrite))
            }
            await sender.disconnect()
            await receiver.disconnect()
        } catch {
            await sender.disconnect()
            await receiver.disconnect()
            throw error
        }
    }

    @Test(arguments: Interruption.allCases)
    func segmentedCancellation(_ interruption: Interruption) async throws {
        let requests = Pipe()
        let responses = Pipe()
        defer {
            for pipe in [requests, responses] {
                try? pipe.fileHandleForReading.close()
                try? pipe.fileHandleForWriting.close()
            }
        }
        let sender = StandardIOTransport(input: responses.fileHandleForReading, output: requests.fileHandleForWriting)
        do {
            try await sender.connect()
            let result = CallTool.Result(content: [
                .text(text: String(repeating: "x", count: 1_048_576), annotations: nil, _meta: nil)
            ])
            let reader = requests.fileHandleForReading
            var encoder = MCPResponseEncoder()
            for id in ["first", "seed"] {
                let response = RPCResponse(id: .string(id), result: result)
                let expected = try MCPResponseEncoder().encode(response) + Data([10])
                let output = try encoder.frame(for: response)
                let warming = Task {
                    if case .contiguous(let frame) = output {
                        try await sender.send(frame, after: nil)
                    } else {
                        try await sender.send(MCPResponseEncoder().encode(response))
                    }
                }
                var frame = Data()
                while frame.count < expected.count {
                    let remaining = expected.count - frame.count
                    let next = try #require(try reader.read(upToCount: min(65_536, remaining)))
                    frame.append(next)
                }
                try await warming.value
                #expect(frame == expected)
            }
            let repeated = try encoder.frame(for: RPCResponse(id: .string("reused"), result: result))
            guard case .segments(let header, let body) = repeated else {
                Issue.record("Expected a cached frame.")
                await sender.disconnect()
                return
            }
            let sending = Task {
                try await sender.send(body, after: header)
            }
            let started = try reader.read(upToCount: 1)
            #expect(started == Data([123]))
            switch interruption {
            case .cancelWrite:
                sending.cancel()
            case .disconnect:
                await sender.disconnect()
            }
            do {
                try await sending.value
                Issue.record("Expected the blocked write to end with an error.")
            } catch {
                #expect(sending.isCancelled == (interruption == .cancelWrite))
            }
            await sender.disconnect()
        } catch {
            await sender.disconnect()
            throw error
        }
    }

    @Test
    func partialFramesPreserveUnicodeAndScanAcrossBufferCompaction() throws {
        var decoder = StandardIOFrameDecoder(maximumMessageBytes: 64)
        var bytes = ByteBufferAllocator().buffer(capacity: 64)
        bytes.writeBytes([10, 0xE2])
        #expect(try decoder.decode(buffer: &bytes) == nil)
        bytes.discardReadBytes()
        bytes.writeBytes([0x80, 0xA8, 13, 10, 10])
        let decoded = try decoder.decode(buffer: &bytes)
        let frame = try #require(decoded)
        #expect(Array(frame.readableBytesView) == [0xE2, 0x80, 0xA8, 13])
        #expect(try decoder.decode(buffer: &bytes) == nil)
        bytes.writeString("tail")
        #expect(try decoder.decodeLast(buffer: &bytes, seenEOF: true) == nil)
        #expect(bytes.readableBytes == 0)
    }

    @Test
    func oversizedFramesAreRejectedBeforeAndAtTheirDelimiter() throws {
        for text in ["12345", "12345\n"] {
            var decoder = StandardIOFrameDecoder(maximumMessageBytes: 4)
            var bytes = ByteBufferAllocator().buffer(capacity: 8)
            bytes.writeString(text)
            #expect(throws: MCPError.self) {
                try decoder.decode(buffer: &bytes)
            }
        }
    }

    @Test
    func inputEOFDrainsFramesAndLeavesOutputAvailableUntilDisconnect() async throws {
        let input = Pipe()
        let output = Pipe()
        let unused = Pipe()
        defer {
            for pipe in [input, output, unused] {
                try? pipe.fileHandleForReading.close()
                try? pipe.fileHandleForWriting.close()
            }
        }
        let transport = StandardIOTransport(input: input.fileHandleForReading, output: output.fileHandleForWriting)
        let reader = StandardIOTransport(input: output.fileHandleForReading, output: unused.fileHandleForWriting)
        do {
            try await transport.connect()
            try await reader.connect()
            try input.fileHandleForWriting.write(contentsOf: Data("one\nunterminated".utf8))
            try input.fileHandleForWriting.close()
            var received: [Data] = []
            for try await message in await transport.receive() {
                received.append(message)
            }
            #expect(received == [Data("one".utf8)])
            try await transport.send(Data("after EOF".utf8))
            var responses = await reader.receive().makeAsyncIterator()
            #expect(try await responses.next() == Data("after EOF".utf8))
            let text = String(repeating: "é", count: 100_000)
            let result = CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)])
            var encoder = MCPResponseEncoder()
            for id in 8...10 {
                let response = RPCResponse(id: .integer(Int64(id)), result: result)
                switch try encoder.frame(for: response) {
                case .segments(let header, let body):
                    try await transport.send(body, after: header)
                case .contiguous(let bytes):
                    try await transport.send(bytes, after: nil)
                case nil:
                    try await transport.send(MCPResponseEncoder().encode(response))
                }
                let frame = try #require(try await responses.next())
                let reply = try JSONDecoder().decode(JSONValue.self, from: frame)
                #expect(reply["id"] == .integer(Int64(id)))
                #expect(
                    reply["result"]?["content"] == .array([.object(["type": .string("text"), "text": .string(text)])]))
            }
            await transport.disconnect()
            await reader.disconnect()
        } catch {
            await transport.disconnect()
            await reader.disconnect()
            throw error
        }
    }

    @Test
    func largeSendFlushesBeforeDisconnectAndPendingReadsTerminate() async throws {
        let requests = Pipe()
        let responses = Pipe()
        defer {
            for pipe in [requests, responses] {
                try? pipe.fileHandleForReading.close()
                try? pipe.fileHandleForWriting.close()
            }
        }
        let server = StandardIOTransport(input: requests.fileHandleForReading, output: responses.fileHandleForWriting)
        let client = StandardIOTransport(input: responses.fileHandleForReading, output: requests.fileHandleForWriting)
        do {
            try await server.connect()
            try await client.connect()
            let payload = Data(repeating: 120, count: 1_048_576)
            let waiting = Task {
                var messages = await client.receive().makeAsyncIterator()
                return try await messages.next()
            }
            let sending = Task {
                try await client.send(payload)
                await client.disconnect()
            }
            var received = await server.receive().makeAsyncIterator()
            #expect(try await received.next() == payload)
            try await sending.value
            #expect(try await waiting.value == nil)
            await server.disconnect()
            await server.disconnect()
            await #expect(throws: MCPError.connectionClosed) {
                try await server.send(Data())
            }
        } catch {
            await server.disconnect()
            await client.disconnect()
            throw error
        }
    }
}
