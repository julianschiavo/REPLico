import Foundation

/// An executable sandbox launcher and its argument prefix, validated before submission.
/// The caller is responsible for ensuring that the launcher enforces the intended restrictions.
public struct SandboxLauncher: Sendable, Equatable {
    /// The canonical absolute executable file URL.
    public let executable: URL
    /// Arguments passed before the Node executable path and its worker arguments.
    public let arguments: [String]

    /// Validates an absolute executable file and NUL-free arguments without launching it.
    /// Throws `REPLError.invalidConfiguration` if the executable or arguments are invalid.
    public init(executable: URL, arguments: [String]) throws {
        guard executable.isFileURL, executable.path.hasPrefix("/"),
            !executable.path.utf8.contains(0),
            arguments.allSatisfy({ !$0.utf8.contains(0) })
        else {
            throw REPLError.invalidConfiguration(
                "A sandbox launcher requires an absolute executable file and NUL-free arguments.")
        }
        let canonical = executable.standardizedFileURL.resolvingSymlinksInPath()
        guard (try? canonical.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
            FileManager.default.isExecutableFile(atPath: canonical.path)
        else {
            throw REPLError.invalidConfiguration("A sandbox launcher must reference an executable file.")
        }
        self.executable = canonical
        self.arguments = arguments
    }
}
