import ReplicoCore

/// Immutable request metadata and the launch policy chosen by the integration.
public struct ToolCallContext: Sendable, Equatable {
    /// Opaque MCP metadata, retained without narrowing unsigned integers.
    public let metadata: [String: JSONValue]
    /// The explicit policy supplied to any REPL evaluation performed by the tool.
    public let launchPolicy: LaunchPolicy

    /// Creates context for a tool invocation; metadata does not grant authority.
    public init(metadata: [String: JSONValue] = [:], launchPolicy: LaunchPolicy = .direct) {
        self.metadata = metadata
        self.launchPolicy = launchPolicy
    }
}
