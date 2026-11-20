import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The ES module graph linked into ReplicoCore, shared by bundled and external Node runtimes.
struct EmbeddedWorker: Sendable {
    static let current = Self(sources: [
        "context.mjs": PackageResources.context_mjs,
        "errors.mjs": PackageResources.errors_mjs,
        "execution-scope.mjs": PackageResources.execution_scope_mjs,
        "images.mjs": PackageResources.images_mjs,
        "kernel.mjs": PackageResources.kernel_mjs,
        "module-loader.mjs": PackageResources.module_loader_mjs,
        "native-evaluator.mjs": PackageResources.native_evaluator_mjs,
        "services.mjs": PackageResources.services_mjs,
        "transport.mjs": PackageResources.transport_mjs,
        "worker.mjs": PackageResources.worker_mjs,
    ])

    private let sources: [String: Data]
    private let key: String

    private init(sources: [String: [UInt8]]) {
        self.sources = sources.mapValues { Data($0) }
        // FNV-1a selects a stable directory. The byte comparison below establishes its contents.
        var fingerprint: UInt64 = 0xcbf2_9ce4_8422_2325
        for file in sources.sorted(by: { $0.key < $1.key }) {
            for byte in Array(file.key.utf8) + [0] + file.value + [0] {
                fingerprint = (fingerprint ^ UInt64(byte)) &* 0x100_0000_01b3
            }
        }
        key = "worker-" + String(fingerprint, radix: 16)
    }

    /// Materializes the complete graph before Node sees the entry point.
    func entryPoint() throws -> URL {
        let cache = try RuntimeResourceCache(key)
        if try !cache.isInstalled {
            let staging = try cache.makeStagingDirectory()
            defer { try? FileManager.default.removeItem(at: staging) }
            for (filename, bytes) in sources {
                try bytes.write(to: staging.appending(component: filename))
            }
            try cache.publish(staging)
        }

        for (filename, bytes) in sources {
            let file = cache.directory.appending(component: filename)
            var info = stat()
            guard lstat(file.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                info.st_size == bytes.count, (try? Data(contentsOf: file)) == bytes
            else {
                throw REPLError.invalidConfiguration(
                    "Invalid cached worker module at \(file.path). Remove \(cache.directory.path) to reinstall it.")
            }
        }
        return cache.directory.appending(component: "worker.mjs")
    }
}
