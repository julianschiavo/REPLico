import MCP

/// An MCP tool with typed arguments, SDK schemas, and an asynchronous action.
///
/// Independent requests can invoke the same tool concurrently. Actions should
/// cooperate with task cancellation and finish their owned resources before returning.
public protocol Tool<Arguments>: Sendable {
    /// The concrete argument type decoded before the action runs.
    associatedtype Arguments: Decodable & Sendable

    /// The native descriptor, captured once when the server registers the tool.
    var definition: MCP.Tool {
        get
    }

    /// Runs the action and returns native MCP content and result metadata.
    func call(arguments: Arguments, context: ToolCallContext) async throws -> CallTool.Result
}
