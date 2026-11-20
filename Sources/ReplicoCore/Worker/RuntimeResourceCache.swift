import Foundation
import SystemPackage
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A directory of embedded runtime files, published in one rename and shared by processes of the same user.
package struct RuntimeResourceCache: Sendable {
    /// The final directory for this version of the resources.
    package let directory: URL

    /// Opens a cache entry beneath the current user's private REPLico cache.
    package init(_ key: String) throws {
        directory = Self.directory(for: key)
        let root = directory.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        if mkdir(root.path, 0o700) != 0 && errno != EEXIST {
            throw Errno(rawValue: errno)
        }
        try Self.requirePrivateDirectory(root)
    }

    /// Computes an entry's destination without inspecting or creating cache files.
    package static func directory(for key: String) -> URL {
        URL.cachesDirectory.appending(component: "REPLico", directoryHint: .isDirectory)
            .appending(component: key, directoryHint: .isDirectory)
    }

    /// Whether a previous install published a private directory at this key.
    package var isInstalled: Bool {
        get throws {
            do {
                try Self.requirePrivateDirectory(directory)
                return true
            } catch Errno.noSuchFileOrDirectory {
                return false
            }
        }
    }

    /// Creates an empty sibling directory for this installation attempt.
    package func makeStagingDirectory() throws -> URL {
        let staging = directory.deletingLastPathComponent()
            .appending(component: UUID().uuidString, directoryHint: .isDirectory)
        guard mkdir(staging.path, 0o700) == 0 else {
            throw Errno(rawValue: errno)
        }
        return staging
    }

    /// Publishes a complete staging directory or accepts an installation that won the race.
    /// The caller removes its staging directory if installation fails or another process publishes first.
    package func publish(_ staging: URL) throws {
        guard rename(staging.path, directory.path) != 0 else {
            return
        }
        let error = Errno(rawValue: errno)
        guard error == .directoryNotEmpty || error == .fileExists else {
            throw error
        }
        try Self.requirePrivateDirectory(directory)
    }

    private static func requirePrivateDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw Errno(rawValue: errno)
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
            info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700
        else {
            throw REPLError.invalidConfiguration("Expected a private runtime cache directory at \(url.path).")
        }
    }
}
