import ReplicoMCP
import ReplicoCore
import Foundation
import Testing

@Suite("MCP EOF lifecycle")
struct ReplicoServerEOFTests {
    @Test("EOF shuts down the session and drains admitted calls")
    func eofShutsDownSession() async throws {
        let messages: [JSONValue] = [
            .object([
                "jsonrpc": .string("2.0"),
                "id": .integer(1),
                "method": .string("initialize"),
                "params": .object([
                    "protocolVersion": .string("2025-11-25"),
                    "clientInfo": .object([
                        "name": .string("ReplicoTests"),
                        "version": .string("1.0.0"),
                    ]),
                    "capabilities": .object([:]),
                ]),
            ]),
            .object([
                "jsonrpc": .string("2.0"),
                "method": .string("notifications/initialized"),
            ]),
            .object([
                "jsonrpc": .string("2.0"),
                "id": .integer(2),
                "method": .string("tools/call"),
                "params": .object([
                    "name": .string("js_reset"),
                    "arguments": .object([:]),
                ]),
            ]),
        ]
        let encoder = JSONEncoder()
        let transport = EndingTransport(messages: try messages.map(encoder.encode))
        let session = try REPLSession(
            configuration: REPLConfiguration(
                nodeExecutable: URL(filePath: "/usr/bin/false"),
                environment: [:]
            ))
        let server = try ReplicoServer(session: session, environment: [:])

        try await server.run(over: transport)

        await #expect(throws: REPLError.closed) {
            _ = try await session.evaluate(EvaluationRequest(code: "1 + 1"))
        }
        let sent = try await transport.sentMessages()
            .map {
                try JSONDecoder().decode(JSONValue.self, from: $0)
            }
        #expect(
            sent.contains { message in
                message.objectValue?["id"] == .integer(1)
                    && message.objectValue?["result"]?.objectValue?["protocolVersion"] == .string("2025-11-25")
            })
    }
}
