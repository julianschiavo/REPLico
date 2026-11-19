import Foundation

/// Options shared by all evaluations in one worker process.
struct WorkerStartup: Encodable, Sendable {
    struct Context: Encodable, Sendable {
        let cwd: String
        let homeDir: String
        let tmpDir: String
        let env: [String: String]
    }

    let textDeltas = true
    let binaryImages = true
    let context: Context
    let startupSource: String
    let serviceNames: [String]

    init(configuration: REPLConfiguration, startupSource: String, serviceNames: [String]) {
        context = Context(
            cwd: configuration.workingDirectory.path,
            homeDir: configuration.environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path,
            tmpDir: configuration.environment["TMPDIR"] ?? FileManager.default.temporaryDirectory.path,
            env: configuration.exposedEnvironment
        )
        self.startupSource = startupSource
        self.serviceNames = serviceNames
    }
}
