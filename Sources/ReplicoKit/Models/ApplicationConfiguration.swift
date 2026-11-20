import ReplicoCore
import ReplicoMCP
import Foundation

/// The application identity and process settings used for a hosted connection.
public struct ApplicationConfiguration: Sendable {
    /// The application name, version, and optional display metadata advertised to MCP clients.
    public var serverInfo: ReplicoServer.Info
    /// The bundled runtime or an explicit executable URL.
    public var nodeRuntime: NodeRuntime
    /// The JavaScript working directory and base for local module imports.
    public var workingDirectory: URL
    /// The environment passed to the worker and interpreted by the host adapter.
    public var environment: [String: String]
    /// Environment values explicitly exposed to JavaScript through nodeRepl.env.
    public var exposedEnvironment: [String: String]
    /// The positive combined text and image budget for each evaluation.
    public var maximumOutputBytes: Int

    /// Defaults to the running application's identity, bundled Node, and the current directory and environment.
    public init(
        serverInfo: ReplicoServer.Info = ReplicoServer.hostInfo,
        nodeRuntime: NodeRuntime = .bundled,
        workingDirectory: URL = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        exposedEnvironment: [String: String] = [:],
        maximumOutputBytes: Int = 16 * 1_024 * 1_024
    ) {
        self.serverInfo = serverInfo
        self.nodeRuntime = nodeRuntime
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.exposedEnvironment = exposedEnvironment
        self.maximumOutputBytes = maximumOutputBytes
    }

    func makeEngineConfiguration() throws -> ReplicoCore.REPLConfiguration {
        try ReplicoCore.REPLConfiguration(
            node: nodeRuntime.executable(),
            workingDirectory: workingDirectory,
            environment: environment,
            exposedEnvironment: exposedEnvironment,
            maximumOutputBytes: maximumOutputBytes
        )
    }
}
