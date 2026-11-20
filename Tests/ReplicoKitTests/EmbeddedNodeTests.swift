import ReplicoCore
@testable import ReplicoNode
import Foundation
import Testing

struct EmbeddedNodeTests {
    @Test
    func simultaneousFirstInstallsPublishOneUsableNodeAndItsLicense() async throws {
        let cache = try RuntimeResourceCache("test-node-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let installation = NodeInstallation(cache: cache)
        async let first = installation.executable()
        async let second = installation.executable()
        let paths = try await [first, second]
        let executable = try #require(paths.first)
        #expect(paths.allSatisfy { $0 == executable })
        #expect(FileManager.default.isExecutableFile(atPath: executable.path))
        let license = try String(contentsOf: cache.directory.appending(path: "LICENSE"), encoding: .utf8)
        #expect(license.contains("Node.js"))
        let attributes = try FileManager.default.attributesOfItem(atPath: executable.path)
        let inode = try #require(attributes[.systemFileNumber] as? UInt64)
        _ = try installation.executable()
        let cachedAttributes = try FileManager.default.attributesOfItem(atPath: executable.path)
        #expect(cachedAttributes[.systemFileNumber] as? UInt64 == inode)
    }

    @Test
    func anIncompletePublishedNodeCannotRun() throws {
        let cache = try RuntimeResourceCache("test-node-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let staging = try cache.makeStagingDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        try Data("incomplete".utf8).write(to: staging.appending(path: "node"))
        try Data("notice".utf8).write(to: staging.appending(path: "LICENSE"))
        try cache.publish(staging)
        #expect(throws: REPLError.self) {
            try NodeInstallation(cache: cache).executable()
        }
    }
}
