import ReplicoCore
import Foundation

/// Selects the Node executable used by a hosted application.
public enum NodeRuntime: Sendable, Equatable {
    /// Use Node included by the default ReplicoKit product.
    case bundled
    /// Use the application's executable file URL instead of a bundled runtime.
    case external(URL)

    func executable() throws -> NodeExecutable {
        switch self {
        case .external(let url):
            return .external(url)
        case .bundled:
            guard let embedded = Self.self as? any EmbeddedNodeRuntime.Type else {
                throw REPLError.invalidConfiguration(
                    "Bundled Node is unavailable. Link ReplicoKit, or select NodeRuntime.external with your executable URL."
                )
            }
            return .embedded(embedded)
        }
    }
}
