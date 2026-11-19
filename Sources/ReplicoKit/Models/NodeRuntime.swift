import Foundation

/// Selects the Node executable used by a hosted application.
public enum NodeRuntime: Sendable, Equatable {
    /// Use Node included by the default ReplicoKit product.
    case bundled
    /// Use the application's executable file URL instead of a bundled runtime.
    case external(URL)
}
