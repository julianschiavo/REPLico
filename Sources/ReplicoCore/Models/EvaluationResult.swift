/// The collected output and JavaScript success status of an evaluation.
public struct EvaluationResult: Sendable, Equatable {
    /// Output items in their presentation order.
    public var content: [REPLContent]
    /// Whether JavaScript evaluation or a tracked helper failed.
    public var didFail: Bool

    /// Creates a result, defaulting to a successful cell with no output.
    public init(content: [REPLContent] = [], didFail: Bool = false) {
        self.content = content
        self.didFail = didFail
    }
}
