@testable import ReplicoMCP
import ReplicoCore
import Foundation
import MCP
import Testing

@Suite("Replico MCP server")
struct ReplicoServerTests {
    @Test("Native argument validation retains numeric range, object shape, and error precedence")
    func nativeArgumentValidation() async throws {
        try await ServerTestConnection.run(tools: [UnsignedTool(), MultiplyTool()]) { connection in
            _ = try await connection.initialize()
            for number in ["18446744073709551615", "1e3", "1.0"] {
                let response = try await connection.request(
                    #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"unsigned","arguments":{"value":\#(number),"ignored":{"nested":[null,true,"text"]}}}}"#
                )
                let expected = number == "18446744073709551615" ? number : number == "1e3" ? "1000" : "1"
                #expect(response["result"]?["content"]?.arrayValue?.first?["text"] == .string(expected))
            }
            for arguments in [
                "[]", "42", "true", #"{"value":1.5}"#, #"{"value":null}"#, #"{"value":1,"ignored":{"nested":1e309}}"#,
            ] {
                let response = try await connection.request(
                    #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"unsigned","arguments":\#(arguments)}}"#
                )
                #expect(response["error"]?["code"] == .integer(-32602))
            }
            let unknown = try await connection.request(
                #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"multiply","arguments":{"value":null,"factor":null,"extra":true}}}"#
            )
            #expect(unknown["error"]?["message"] == .string("Invalid params: Unexpected arguments: extra."))
            let scalar = try await connection.request(
                #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"multiply","arguments":{"value":null,"factor":null}}}"#
            )
            #expect(scalar["error"]?["message"] == .string("Invalid params: factor must be an integer."))
        }
    }

    @Test("Registration captures one descriptor for discovery and invocation")
    func capturedDescriptor() async throws {
        try await ServerTestConnection.run(tools: [GeneratedDescriptorTool()]) { connection in
            _ = try await connection.initialize()
            let listing = try await connection.request(
                .object([
                    "jsonrpc": .string("2.0"), "id": .integer(2), "method": .string("tools/list"),
                ]))
            let name = try #require(listing["result"]?["tools"]?.arrayValue?.first?["name"])
            let result = try await connection.request(
                .object([
                    "jsonrpc": .string("2.0"), "id": .integer(3), "method": .string("tools/call"),
                    "params": .object(["name": name]),
                ]))
            #expect(result["result"]?["content"]?.arrayValue?.first?["text"] == .string("called"))
        }
    }

    @Test("Typed custom tools are discovered and dispatched through the registry")
    func customToolRegistry() async throws {
        try await ServerTestConnection.run(tools: [MultiplyTool()]) { connection in
            _ = try await connection.initialize(clientName: HostIntegration.clientName)
            let listing = try await connection.request(
                .object([
                    "jsonrpc": .string("2.0"),
                    "id": .integer(2),
                    "method": .string("tools/list"),
                ]))
            let tools = try #require(listing["result"]?["tools"]?.arrayValue)
            #expect(tools.map { $0["name"] } == [.string("multiply")])
            #expect(tools[0]["annotations"]?["readOnlyHint"] == .bool(true))
            let result = try await connection.request(
                .object([
                    "jsonrpc": .string("2.0"),
                    "id": .integer(3),
                    "method": .string("tools/call"),
                    "params": .object([
                        "name": .string("multiply"),
                        "arguments": .object(["value": .integer(6), "factor": .integer(7)]),
                        "_meta": .object(["label": .string("registry")]),
                    ]),
                ]))
            #expect(result["result"]?["content"]?.arrayValue?.first?["text"] == .string("42:registry:true"))
            #expect(result["result"]?["structuredContent"]?["value"] == .integer(42))
            #expect(result["result"]?["_meta"]?["custom"] == .bool(true))
            let invalid = try await connection.request(
                .object([
                    "jsonrpc": .string("2.0"),
                    "id": .integer(4),
                    "method": .string("tools/call"),
                    "params": .object([
                        "name": .string("multiply"),
                        "arguments": .object(["value": .string("six"), "factor": .integer(7)]),
                    ]),
                ]))
            #expect(invalid["error"]?["code"] == .integer(-32602))
        }
    }

    @Test("An official MCP client initializes and discovers the tools")
    func officialClientInteroperability() async throws {
        let pair = await InMemoryTransport.createConnectedPair()
        try await pair.server.connect()
        let session = try REPLSession(
            configuration: REPLConfiguration(
                nodeExecutable: URL(filePath: "/usr/bin/false"),
                environment: [:]
            ))
        let server = try ReplicoServer(session: session, environment: [:])
        let serverTask = Task {
            try await server.run(over: pair.server)
        }
        let client = Client(name: "ReplicoTests", version: "1.0.0")
        do {
            let initialized = try await client.connect(transport: pair.client)
            #expect(initialized.serverInfo.name == ProcessInfo.processInfo.processName)
            #expect(initialized.capabilities.tools != nil)
            let listed = try await client.listTools()
            #expect(
                Set(listed.tools.map(\.name)) == [
                    "js", "js_reset", "js_add_node_module_dir",
                ])
            await client.disconnect()
            try await serverTask.value
            await #expect(throws: MCPError.self) {
                try await server.run(over: pair.server)
            }
            await #expect(throws: REPLError.closed) {
                _ = try await session.evaluate(EvaluationRequest(code: "1 + 1"))
            }
        } catch {
            await client.disconnect()
            try await serverTask.value
            throw error
        }
    }

    @Test("The sandbox capability and protocol negotiation survive initialization")
    func sandboxCapabilityAndProtocolNegotiation() async throws {
        try await ServerTestConnection.run { connection in
            let response = try await connection.initialize(
                id: .string("initialize-request"),
                version: "2025-06-18"
            )
            #expect(response.objectValue?["id"] == .string("initialize-request"))
            let result = try #require(response.objectValue?["result"]?.objectValue)
            #expect(result["protocolVersion"] == .string("2025-06-18"))
            let experimental = result["capabilities"]?.objectValue?["experimental"]?.objectValue
            #expect(experimental?[HostIntegration.sandboxStateKey] == .object([:]))
        }
    }

    @Test("Tools require initialization and malformed calls return protocol errors")
    func protocolValidation() async throws {
        try await ServerTestConnection.run { connection in
            let beforeInitialization = try await connection.request(
                .object([
                    "jsonrpc": .string("2.0"),
                    "id": .integer(7),
                    "method": .string("tools/list"),
                ]))
            #expect(beforeInitialization.objectValue?["id"] == .integer(7))
            #expect(beforeInitialization.objectValue?["error"]?.objectValue?["code"] == .integer(-32600))
            _ = try await connection.initialize()
            let invalidCall = try await connection.request(
                .object([
                    "jsonrpc": .string("2.0"),
                    "id": .integer(8),
                    "method": .string("tools/call"),
                    "params": .object([
                        "name": .string("js"),
                        "arguments": .object(["code": .integer(42)]),
                    ]),
                ]))
            #expect(invalidCall.objectValue?["error"]?.objectValue?["code"] == .integer(-32602))
            let unknownMethod = try await connection.request(
                .object([
                    "jsonrpc": .string("2.0"),
                    "id": .string("unknown"),
                    "method": .string("unimplemented/method"),
                ]))
            #expect(unknownMethod.objectValue?["error"]?.objectValue?["code"] == .integer(-32601))
        }
    }

    @Test("A kernel reset responds without launching Node")
    func resetWithoutStartingKernel() async throws {
        try await ServerTestConnection.run { connection in
            _ = try await connection.initialize()
            for parameters in [
                JSONValue.object(["name": .string("js_reset"), "arguments": .object([:])]),
                .object(["name": .string("js_reset")]),
                .object(["name": .string("js_reset"), "arguments": .null]),
            ] {
                let reset = try await connection.request(
                    .object([
                        "jsonrpc": .string("2.0"),
                        "id": .string(UUID().uuidString),
                        "method": .string("tools/call"),
                        "params": parameters,
                    ]))
                #expect(reset.objectValue?["result"]?.objectValue?["isError"] == .bool(false))
            }
        }
    }
}
