import Foundation
import Testing
@testable import ReplicoCore

struct RuntimeResourceCacheTests {
    @Test
    func concurrentInstallsExposeOneCompleteDirectory() throws {
        let cache = try RuntimeResourceCache(UUID().uuidString)
        let first = try cache.makeStagingDirectory()
        defer { try? FileManager.default.removeItem(at: first) }
        let second = try cache.makeStagingDirectory()
        defer { try? FileManager.default.removeItem(at: second) }
        defer { try? FileManager.default.removeItem(at: cache.directory) }

        try Data("first".utf8).write(to: first.appending(component: "worker"))
        try Data("second".utf8).write(to: second.appending(component: "worker"))
        #expect(try !cache.isInstalled)
        try cache.publish(first)
        try cache.publish(second)

        #expect(try cache.isInstalled)
        #expect(try String(contentsOf: cache.directory.appending(component: "worker"), encoding: .utf8) == "first")
    }

    @Test
    func installedDirectoryMustBelongToThePrivateCache() throws {
        let cache = try RuntimeResourceCache(UUID().uuidString)
        let other = try cache.makeStagingDirectory()
        defer { try? FileManager.default.removeItem(at: other) }
        try FileManager.default.createSymbolicLink(at: cache.directory, withDestinationURL: other)
        defer { try? FileManager.default.removeItem(at: cache.directory) }

        #expect(throws: REPLError.self) {
            try cache.isInstalled
        }
    }
}
