/// Immutable execution identity and application metadata passed to a tool.
/// Metadata does not grant permissions or change the worker's launch policy.
public struct ToolContext: Sendable, Equatable {
    /// The evaluation that originated this call.
    public let executionID: String
    /// Metadata captured when that evaluation was admitted.
    public let metadata: [String: JSONValue]

    /// Creates a context for one originating evaluation.
    public init(executionID: String, metadata: [String: JSONValue] = [:]) {
        self.executionID = executionID
        self.metadata = metadata
    }
}
