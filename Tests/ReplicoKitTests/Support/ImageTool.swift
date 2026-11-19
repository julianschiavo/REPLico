import ReplicoKit
import Foundation

struct ImageTool: Tool {
    typealias Arguments = NoArguments
    let name = "image"
    let image: Data

    func call(arguments: NoArguments, context: ToolContext) async throws -> ToolResponse<String> {
        ToolResponse(value: "image", content: [.image(data: image, mimeType: "image/png")])
    }
}
