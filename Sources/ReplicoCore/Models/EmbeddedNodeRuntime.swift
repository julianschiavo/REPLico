import Foundation

/// A linked Node payload that can provide its destination before installing the executable.
package protocol EmbeddedNodeRuntime: Sendable {
    /// The filesystem location reserved for this version of the executable.
    static var executableURL: URL {
        get
    }

    /// Installs the runtime if needed and returns the path to launch.
    static func installedExecutable() throws -> URL
}
