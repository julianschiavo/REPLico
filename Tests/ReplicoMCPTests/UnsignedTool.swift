import ReplicoMCP
import MCP

struct UnsignedTool: ReplicoMCP.Tool {
    struct Arguments: Decodable, Sendable {
        let value: UInt64
    }

    let definition = MCP.Tool(
        name: "unsigned",
        description: "Return a full-width unsigned integer.",
        inputSchema: [
            "type": "object",
            "properties": ["value": ["type": "integer"]],
            "required": ["value"],
        ]
    )

    func call(arguments: Arguments, context: ToolCallContext) async throws -> CallTool.Result {
        CallTool.Result(content: [.text(text: String(arguments.value), annotations: nil, _meta: nil)])
    }
}
