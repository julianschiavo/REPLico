import Foundation

/// A tool registry contains an empty or duplicate name.
public enum ToolRegistrationError: Error, LocalizedError, Sendable, Equatable {
    /// A tool's captured descriptor has an empty name.
    case emptyName
    /// Two captured descriptors use the same name.
    case duplicateName(String)

    /// The registration failure's localized description.
    public var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Tool names must not be empty."
        case .duplicateName(let name):
            return "Duplicate tool name: \(name)."
        }
    }
}
