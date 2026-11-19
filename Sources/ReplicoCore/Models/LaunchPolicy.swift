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
        let arguments = [
            "--experimental-vm-modules", "--experimental-import-meta-resolve",
            configuration.workerDirectory.appending(path: "worker.mjs").path,
        ]
        switch self {
        case .direct:
            return WorkerLaunch(executable: configuration.nodeExecutable, arguments: arguments)
        case .sandboxed(let launcher):
            return WorkerLaunch(
                executable: launcher.executable,
                arguments: launcher.arguments + [configuration.nodeExecutable.path] + arguments
            )
        case .unavailable(let error):
            throw error
        }
    }
}
