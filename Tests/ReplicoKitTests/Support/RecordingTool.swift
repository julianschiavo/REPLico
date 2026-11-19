import ReplicoKit

actor RecordingTool: Tool {
    @ToolArguments
    struct Arguments {
        @Argument(description: "Text to repeat.")
        let text: String
        @Argument(description: "Optional repetition count.")
        let count: Int?
    }

    nonisolated let name = "echo"
    nonisolated let description = "Repeat text and emit the host output."
    private var receivedContexts: [ToolContext] = []

    func call(arguments: Arguments, context: ToolContext) async throws -> ToolResponse<String> {
        receivedContexts.append(context)
        let value = Array(repeating: arguments.text, count: arguments.count ?? 1).joined()
        return ToolResponse(value: value, content: [.text("host:" + value)])
    }

    func contexts() -> [ToolContext] {
        receivedContexts
    }
}
