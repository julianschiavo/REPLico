import ReplicoMCP
import MCP
import Testing

struct RepeatedCallTests {
    private actor FreshArgumentsTool: ReplicoMCP.Tool {
        final class Arguments: Decodable, Sendable {
            init(from decoder: any Decoder) {
            }
        }

        nonisolated let definition = MCP.Tool(name: "js", description: nil, inputSchema: ["type": "object"])
        private var preceding: Arguments?

        func call(arguments: Arguments, context: ToolCallContext) async throws -> CallTool.Result {
            let text = preceding === arguments ? "reused" : "fresh"
            preceding = arguments
            return CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)])
        }
    }

    @Test
    func repeatedRequestsDecodeCustomToolArgumentsForEachCall() async throws {
        try await ServerTestConnection.run(tools: [FreshArgumentsTool()]) { connection in
            _ = try await connection.initialize()
            for id in 2...4 {
                let frame =
                    #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"js","arguments":{}}}"#
                let response = try await connection.request(frame)
                #expect(response["result"]?["content"]?.arrayValue?.first?["text"] == .string("fresh"))
            }
        }
    }

    @Test(arguments: [
        #"{"code":" ","title":null}"#, #"{"code":" ","timeout_ms":null}"#,
        #"{"code":" ","unexpected":2}"#, #"{"code":" ","title":3}"#,
    ])
    func explicitNullOrUnknownArgumentsKeepTheirSchemaErrors(_ arguments: String) async throws {
        try await ServerTestConnection.run { connection in
            _ = try await connection.initialize()
            let frame =
                #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"js","arguments":\#(arguments)}}"#
            let response = try await connection.request(frame)
            #expect(response["error"]?["code"] == .integer(-32602))
        }
    }
}
