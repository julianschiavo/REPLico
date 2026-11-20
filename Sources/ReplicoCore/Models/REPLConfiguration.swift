import Foundation

/// Process configuration fixed when a session is created.
public struct REPLConfiguration: Sendable {
    /// The pinned Node 26.13.1 executable used to launch workers.
    public var nodeExecutable: URL {
        get {
            node.url
        }
        set {
            node = .external(newValue)
        }
    }
    private(set) var node: NodeExecutable
    /// The worker working directory and base for local module resolution.
    public var workingDirectory: URL
    /// The worker process environment; application adapters interpret any host-specific entries.
    public var environment: [String: String]
    /// Environment entries explicitly exposed through `nodeRepl.env`.
    public var exposedEnvironment: [String: String]
    /// The positive combined text and image budget for each evaluation.
    /// Final JavaScript failure diagnostics remain visible beyond this budget.
    public var maximumOutputBytes: Int

    /// Creates worker configuration with the current directory and inherited process environment by default.
    public init(
        nodeExecutable: URL,
        workingDirectory: URL = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        exposedEnvironment: [String: String] = [:],
        maximumOutputBytes: Int = 16 * 1_024 * 1_024
    ) {
        self.init(
            node: .external(nodeExecutable), workingDirectory: workingDirectory, environment: environment,
            exposedEnvironment: exposedEnvironment, maximumOutputBytes: maximumOutputBytes
        )
    }

    /// Creates a session configuration without installing the selected Node runtime.
    package init(
        node: NodeExecutable, workingDirectory: URL, environment: [String: String],
        exposedEnvironment: [String: String], maximumOutputBytes: Int
    ) {
        self.node = node
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.exposedEnvironment = exposedEnvironment
        self.maximumOutputBytes = maximumOutputBytes
    }

}
