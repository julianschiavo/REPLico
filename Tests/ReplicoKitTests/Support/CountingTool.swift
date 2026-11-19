import ReplicoKit

actor CountingTool: Tool {
    typealias Arguments = NoArguments
    nonisolated let name = "empty"
    private var count = 0

    func call(arguments: NoArguments, context: ToolContext) async throws -> ToolResponse<Int> {
        count += 1
        return ToolResponse(value: count)
    }

    func invocationCount() -> Int {
        count
    }
}
