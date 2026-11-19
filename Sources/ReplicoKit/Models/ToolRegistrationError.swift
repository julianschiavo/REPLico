import Foundation

/// A tool registration that cannot form an unambiguous JavaScript API.
public enum ToolRegistrationError: Error, Sendable, Equatable, LocalizedError {
    /// A group name is not a supported JavaScript identifier or is a reserved word.
    case invalidGroupName(String)
    /// More than one group uses the same JavaScript namespace.
    case duplicateGroupName(String)
    /// A tool name is not a supported JavaScript method identifier.
    case invalidToolName(group: String, name: String)
    /// More than one tool in a group uses the same method name.
    case duplicateToolName(group: String, name: String)
    /// A tool's argument schema is not an encodable JSON object schema.
    case invalidArgumentsSchema(group: String, name: String)

    /// A description of the invalid registration.
    public var errorDescription: String? {
        switch self {
        case .invalidGroupName(let name):
            return "Invalid or reserved JavaScript namespace: \(name)."
        case .duplicateGroupName(let name):
            return "Duplicate JavaScript namespace: \(name)."
        case .invalidToolName(let group, let name):
            return "Invalid JavaScript method name: \(group).\(name)."
        case .duplicateToolName(let group, let name):
            return "Duplicate JavaScript method: \(group).\(name)."
        case .invalidArgumentsSchema(let group, let name):
            return "Tool arguments must have an object schema: \(group).\(name)."
        }
    }
}
