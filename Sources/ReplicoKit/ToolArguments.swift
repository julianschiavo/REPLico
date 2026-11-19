/// Generates argument decoding conformance and a JSON schema from stored properties.
///
/// Properties require `@Argument(description:)` and an explicit primitive, array,
/// or optional type. Defaults, dictionaries, custom types, and computed properties
/// are diagnosed at compile time. Optional properties may be omitted.
@attached(member, names: named(schema))
@attached(extension, conformances: ToolArgumentsProtocol)
public macro ToolArguments() = #externalMacro(module: "ReplicoKitMacros", type: "ToolArgumentsMacro")

/// Describes one stored property of an `@ToolArguments` declaration for API discovery.
@attached(peer)
public macro Argument(description: String) = #externalMacro(module: "ReplicoKitMacros", type: "ArgumentMacro")
