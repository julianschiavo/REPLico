import ReplicoCore
import MCP

/// Discards the current kernel while retaining the server's session.
public struct ResetTool: Tool {
    /// Reset accepts an empty argument object.
    public typealias Arguments = MCP.Empty

    private let session: REPLSession

    /// Binds the tool to the session it resets.
    public init(session: REPLSession) {
        self.session = session
    }

    /// The js_reset tool's advertised schema and operational hints.
    public let definition = MCP.Tool(
        name: "js_reset",
        description: "Reset the JavaScript kernel and clear its bindings.",
        inputSchema: ["type": "object", "properties": [:], "required": [], "additionalProperties": false],
        annotations: .init(readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false)
    )

    /// Interrupts active evaluation and discards the kernel's bindings.
    public func call(arguments: Arguments, context: ToolCallContext) async throws -> CallTool.Result {
        await session.reset()
        return EvaluationResult(content: [.text("JavaScript kernel reset.")]).makeMCPResult()
    }
}
