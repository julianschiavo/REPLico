import ReplicoKit

/// Exercises macro synthesis on a public argument model.
@ToolArguments
public struct PublicArguments {
    /// The unsigned integer supplied on the wire.
    @Argument(description: "An unsigned integer preserved without narrowing.")
    public let value: UInt64
}
