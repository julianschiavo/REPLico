import ReplicoCore

/// The canonical JSON data model shared by tool schemas and immutable metadata.
public typealias JSONValue = ReplicoCore.JSONValue

/// Typed tool arguments and their JSON Schema description.
///
/// Use `@ToolArguments` to synthesize the schema for supported stored properties,
/// or implement the schema explicitly for a custom `Decodable` representation.
public protocol ToolArgumentsProtocol: Decodable, Sendable {
    /// The JSON Schema for the complete argument object.
    /// A schema forbidding additional properties must include an object-valued `properties`.
    static var schema: JSONValue {
        get
    }
}
