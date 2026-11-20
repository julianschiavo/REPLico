import Foundation

/// The source of the Node executable for a session.
package enum NodeExecutable: Sendable {
    /// Use the executable supplied by the application.
    case external(URL)
    /// Install the linked runtime when the session launches its first worker.
    case embedded(any EmbeddedNodeRuntime.Type)

    var url: URL {
        switch self {
        case .external(let url): url
        case .embedded(let runtime): runtime.executableURL
        }
    }

    func installedURL() throws -> URL {
        switch self {
        case .external(let url): url
        case .embedded(let runtime): try runtime.installedExecutable()
        }
    }
}
