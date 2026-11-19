@testable import ReplicoMCP
import ReplicoCore
import ReplicoOptimizations
import Foundation
import Testing

struct CanonicalHeaderProtocolTests {
    @Test(arguments: [UInt64(0), 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max])
    func responsePreservesTheFoundationRequestID(_ id: UInt64) async throws {
        let source =
            #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"multiply","arguments":{"value":6,"factor":7},"ignored":1e400}}"#
        let data = Data(source.utf8)
        _ = try JSONDocument(validating: data)
        let baseline = try JSONDecoder().decode(MessageHeader.self, from: data)
        let recognized = try #require(CanonicalToolCallHeader(frame: data))
        let optimized = MessageHeader(toolCallID: recognized.id)
        #expect(optimized.version == baseline.version)
        #expect(optimized.method == baseline.method)
        #expect(optimized.requestID == baseline.requestID)
        try await ServerTestConnection.run(tools: [MultiplyTool()]) { connection in
            _ = try await connection.initialize()
            let response = try await connection.request(source)
            #expect(response["id"] == baseline.requestID)
            #expect(response["result"]?["structuredContent"]?["value"] == .integer(42))
        }
    }

    @Test(arguments: [511, 512, 513])
    func enclosingDepthMatchesFoundationHeaderAndTypedAdmission(_ totalDepth: Int) async throws {
        let count = totalDepth - 2
        let nested = String(repeating: "[", count: count) + "1e400" + String(repeating: "]", count: count)
        let data = Data(
            #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"multiply","arguments":{"value":6,"factor":7},"ignored":\#(nested)}}"#
                .utf8)
        if totalDepth <= 512 {
            _ = try JSONDocument(validating: data)
            let recognized = try #require(CanonicalToolCallHeader(frame: data))
            let baseline = try JSONDecoder().decode(MessageHeader.self, from: data)
            let admitted = try JSONDecoder()
                .decode(MCPToolCall.self, from: data, configuration: [RegisteredTool(MultiplyTool())])
            #expect(MessageHeader(toolCallID: recognized.id).requestID == baseline.requestID)
            let result = try await admitted.invocation.invoke(context: ToolCallContext())
            #expect(result.structuredContent == .object(["value": .int(42)]))
        } else {
            #expect(CanonicalToolCallHeader(frame: data) == nil)
            #expect(throws: DecodingError.self) {
                try JSONDocument(validating: data)
            }
        }
    }

    @Test
    func canonicalRoutingKeepsSyntaxStateAndArgumentErrorPriority() async throws {
        try await ServerTestConnection.run(tools: [MultiplyTool()]) { connection in
            let malformed = try await connection.request(
                #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"ignored":"\q"}}"#)
            #expect(malformed["error"]?["code"] == .integer(-32700))
            #expect(malformed["id"] == .null)
            let premature = try await connection.request(
                #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"missing","arguments":null}}"#)
            #expect(premature["error"]?["code"] == .integer(-32600))
            #expect(premature["id"] == .integer(8))
            _ = try await connection.initialize()
            let arguments = try await connection.request(
                #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"multiply","arguments":null}}"#)
            #expect(arguments["error"]?["code"] == .integer(-32602))
            let largeID = try await connection.request(
                #"{"jsonrpc":"2.0","id":18446744073709551615,"method":"tools/call","params":{"name":"multiply","arguments":{"value":6,"factor":7}}}"#
            )
            #expect(largeID["id"] == .unsignedInteger(UInt64.max))
            #expect(largeID["result"]?["structuredContent"]?["value"] == .integer(42))
        }
    }
}
