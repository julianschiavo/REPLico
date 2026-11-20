import ReplicoCore
import ReplicoKit
import ReplicoRuntimeArtifact
import Foundation

extension NodeRuntime: EmbeddedNodeRuntime {
    private static let cacheKey = "node-\(REPLICO_NODE_VERSION)-\(REPLICO_NODE_SHA256)"

    /// The linked Node's eventual executable path, without opening the cache.
    package static var executableURL: URL {
        RuntimeResourceCache.directory(for: cacheKey).appending(path: "node")
    }

    /// Locates or installs the executable for the first worker that needs it.
    package static func installedExecutable() throws -> URL {
        let cache = try RuntimeResourceCache(cacheKey)
        return try NodeInstallation(cache: cache).executable()
    }
}
