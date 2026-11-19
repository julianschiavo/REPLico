import ReplicoCore
import ReplicoOptimizations
import MCP

/// Binds the descriptor captured at registration to the action it describes.
struct RegisteredTool: Sendable {
    let definition: MCP.Tool
    private let action: any Tool

    init(_ action: any Tool) {
        definition = action.definition
        self.action = action
    }

    func prepareJavaScript(from parameters: KeyedDecodingContainer<MCPToolCall.ParameterKey>) -> (any ToolInvocation)? {
        guard let script = action as? JavaScriptTool,
            let object = try? parameters.decode(DecodedJSONObject<JavaScriptTool.Arguments>.self, forKey: .arguments)
        else {
            return nil
        }
        // Each decoded non-nil property proves that its own key was present. Any
        // additional key, including an explicit null, needs the schema diagnostic.
        let arguments = object.value
        let recognized = 1 + (arguments.title == nil ? 0 : 1) + (arguments.timeoutMilliseconds == nil ? 0 : 1)
        guard object.fieldCount == recognized else {
            return nil
        }
        return PreparedToolInvocation(action: script, arguments: arguments)
    }

    func prepare(_ values: [String: JSONValue], from parameters: KeyedDecodingContainer<MCPToolCall.ParameterKey>)
        throws
        -> any ToolInvocation
    {
        let schema = definition.inputSchema.objectValue ?? [:]
        let properties = schema["properties"]?.objectValue ?? [:]
        if schema["additionalProperties"]?.boolValue == false {
            let unknown = Set(values.keys).subtracting(properties.keys)
            guard unknown.isEmpty else {
                throw MCPError.invalidParams("Unexpected arguments: \(unknown.sorted().joined(separator: ", ")).")
            }
        }
        // Codable handles required fields and nested types. Preserve strict scalar
        // validation for optional strings and integral numeric arguments.
        for key in values.keys.sorted() {
            guard let value = values[key], let type = properties[key]?.objectValue?["type"]?.stringValue else {
                continue
            }
            switch type {
            case "string":
                guard value.stringValue != nil else {
                    throw MCPError.invalidParams("\(key) must be a string.")
                }
            case "integer":
                switch value {
                case .integer, .unsignedInteger:
                    break
                default:
                    throw MCPError.invalidParams("\(key) must be an integer.")
                }
            default:
                break
            }
        }
        return try action.prepareInvocation(from: parameters)
    }
}
