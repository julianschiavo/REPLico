import Foundation

/// The process authority a caller selects independently of application metadata.
/// Once a non-direct request reaches the front of the queue, sandboxing remains mandatory, including after reset.
public enum LaunchPolicy: Sendable, Equatable {
    /// Launch Node directly with the session's process configuration.
    case direct
    /// Launch Node through a caller-supplied sandbox executable and argument prefix.
    case sandboxed(SandboxLauncher)
    /// Reject the queued evaluation because required authority could not be established.
    case unavailable(REPLError)

    func makeWorkerLaunch(configuration: REPLConfiguration) throws -> WorkerLaunch {
        let executable: URL
        var arguments: [String]
        switch self {
        case .direct:
            executable = try configuration.node.installedURL()
            arguments = []
        case .sandboxed(let launcher):
            executable = launcher.executable
            arguments = launcher.arguments + [try configuration.node.installedURL().path]
        case .unavailable(let error):
            throw error
        }
        arguments += [
            "--experimental-vm-modules", "--experimental-import-meta-resolve",
            try EmbeddedWorker.current.entryPoint().path,
        ]
        return WorkerLaunch(executable: executable, arguments: arguments)
    }
}
