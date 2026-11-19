/// A host service result returned to JavaScript and optional presentation output.
public struct ServiceResponse: Sendable {
    /// The value encoded directly into the Promise reply returned by `nodeRepl.rpc`.
    public let value: any Encodable & Sendable
    /// Text or image output emitted into the evaluation result when the service completes.
    public let content: [REPLContent]

    /// Creates a response with optional output items.
    public init(value: JSONValue, content: [REPLContent] = []) {
        self.value = value
        self.content = content
    }

    /// Creates a typed response whose value is encoded once, when the worker reply is written.
    public init<Value: Encodable & Sendable>(value: Value, content: [REPLContent] = []) {
        self.value = value
        self.content = content
    }
}
