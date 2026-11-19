/// An empty argument object for a tool that takes no inputs.
public struct NoArguments: ToolArgumentsProtocol, Equatable {
    /// The schema of an object with no properties.
    public static var schema: JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false),
        ])
    }

    /// Creates an empty argument object.
    public init() {
    }
}
