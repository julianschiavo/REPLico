import ReplicoMCP
import Foundation
import MCP

struct GeneratedDescriptorTool: ReplicoMCP.Tool {
    typealias Arguments = MCP.Empty

    var definition: MCP.Tool {
        MCP.Tool(name: UUID().uuidString, description: nil, inputSchema: ["type": "object"])
    }

    func call(arguments: Arguments, context: ToolCallContext) async throws -> CallTool.Result {
        CallTool.Result(content: [.text(text: "called", annotations: nil, _meta: nil)])
    }
}
