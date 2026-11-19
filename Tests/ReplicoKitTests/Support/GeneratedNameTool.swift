import ReplicoKit
import Foundation

struct GeneratedNameTool: Tool {
    typealias Arguments = NoArguments

    var name: String {
        "tool" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    var description: String {
        UUID().uuidString
    }

    func call(arguments: NoArguments, context: ToolContext) async throws -> ToolResponse<String> {
        ToolResponse(value: "captured")
    }
}
