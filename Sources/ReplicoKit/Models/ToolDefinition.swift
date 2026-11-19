/// A tool's immutable discovery information, captured when its group is created.
public struct ToolDefinition: Sendable, Equatable {
    /// The method name inside the group's JavaScript namespace.
    public let name: String
    /// A description of the action and when to use it.
    public let description: String
    /// JSON Schema for the tool's argument object.
    public let argumentsSchema: JSONValue
}
