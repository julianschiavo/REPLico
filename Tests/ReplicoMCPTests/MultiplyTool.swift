import ReplicoMCP
import MCP

struct MultiplyTool: ReplicoMCP.Tool {
    struct Arguments: Decodable, Sendable {
        let value: Int
        let factor: Int
    }

    let definition = MCP.Tool(
        name: "multiply",
        description: "Multiply two integers.",
        inputSchema: [
            "type": "object",
            "properties": ["value": ["type": "integer"], "factor": ["type": "integer"]],
            "required": ["value", "factor"],
            "additionalProperties": false,
        ],
        annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    func call(arguments: Arguments, context: ToolCallContext) async throws -> CallTool.Result {
        let product = arguments.value * arguments.factor
        return CallTool.Result(
            content: [
                .text(
                    text:
                        "\(product):\(context.metadata["label"]?.stringValue ?? ""):\(context.launchPolicy != .direct)",
                    annotations: nil, _meta: nil
                )
            ],
            structuredContent: .object(["value": .int(product)]),
            isError: false,
            _meta: Metadata(additionalFields: ["custom": .bool(true)])
        )
    }
}
