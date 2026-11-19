/// A JavaScript cell and the authority and metadata associated with its execution.
public struct EvaluationRequest: Sendable, Equatable {
    /// JavaScript source, limited to 1 MiB when submitted.
    public var code: String
    /// An optional display label; it does not affect JavaScript execution.
    public var title: String?
    /// A positive execution budget that excludes queue time, worker startup,
    /// and command serialization.
    public var timeout: Duration
    /// Immutable application metadata exposed to execution-scoped helpers and services.
    /// Metadata does not grant process permissions or select a launch policy.
    public let metadata: [String: JSONValue]
    /// The explicit process authority required when this request reaches the front of the queue.
    public let launchPolicy: LaunchPolicy

    /// Creates a cell request with a default execution budget of 30 seconds.
    public init(
        code: String,
        title: String? = nil,
        timeout: Duration = .seconds(30),
        metadata: [String: JSONValue] = [:],
        launchPolicy: LaunchPolicy = .direct
    ) {
        self.code = code
        self.title = title
        self.timeout = timeout
        self.metadata = metadata
        self.launchPolicy = launchPolicy
    }
}
