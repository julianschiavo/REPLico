import ReplicoCore

/// Canonical text or image output shared with the underlying evaluation engine.
public typealias ToolContent = ReplicoCore.REPLContent

/// A typed JavaScript return value and optional output emitted by a tool.
public struct ToolResponse<Value: Encodable & Sendable>: Sendable {
    /// The value that fulfills the Promise returned by the JavaScript facade.
    public let value: Value
    /// Ordered text or image items added to the evaluation's presentation output.
    public let content: [ToolContent]

    /// Creates a response with optional presentation output.
    public init(value: Value, content: [ToolContent] = []) {
        self.value = value
        self.content = content
    }
}
