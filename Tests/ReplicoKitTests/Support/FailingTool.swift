import ReplicoKit

struct FailingTool: Tool {
    private enum Failure: Error {
        case rejected
    }

    typealias Arguments = NoArguments
    typealias Output = String
    let name = "fail"

    func call(arguments: NoArguments, context: ToolContext) async throws -> ToolResponse<String> {
        throw Failure.rejected
    }
}
