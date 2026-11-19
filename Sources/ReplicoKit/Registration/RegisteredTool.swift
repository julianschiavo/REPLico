import ReplicoCore

/// Keeps a frozen descriptor bound to the implementation it describes.
struct RegisteredTool: REPLService {
    let name: String
    let definition: ToolDefinition
    private let implementation: any Tool

    init<T: Tool>(_ tool: T, namespace: String) {
        definition = ToolDefinition(
            name: tool.name, description: tool.description, argumentsSchema: T.Arguments.schema)
        name = namespace + "." + definition.name
        implementation = tool
    }

    func call(_ request: ServiceRequest) async throws -> ServiceResponse {
        guard let arguments = request.payload.objectValue else {
            throw REPLError.invalidRequest("Tool arguments must be a JSON object.")
        }
        if definition.argumentsSchema["additionalProperties"] == .bool(false) {
            let properties = definition.argumentsSchema["properties"]?.objectValue ?? [:]
            let unknown = Set(arguments.keys).subtracting(properties.keys)
            guard unknown.isEmpty else {
                throw REPLError.invalidRequest(
                    "Unexpected tool arguments: \(unknown.sorted().joined(separator: ", ")).")
            }
        }
        return try await implementation.invoke(request)
    }
}
