import ReplicoMCP
import Foundation
import MCP

struct URLArgumentsTool: ReplicoMCP.Tool {
    typealias Arguments = URL

    let definition = MCP.Tool(
        name: "url",
        description: "Exercise Foundation's specialized URL decoding.",
        inputSchema: ["type": "object"]
    )

    func call(arguments: URL, context: ToolCallContext) async throws -> CallTool.Result {
        CallTool.Result(content: [.text(text: arguments.absoluteString, annotations: nil, _meta: nil)])
    }
}
