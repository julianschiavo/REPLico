import MCP

/// A sendable action whose concrete arguments have already been decoded and validated.
protocol ToolInvocation: Sendable {
    func invoke(context: ToolCallContext) async throws -> CallTool.Result
}
