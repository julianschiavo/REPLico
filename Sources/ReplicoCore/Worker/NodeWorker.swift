import ReplicoOptimizations
import Foundation
import NIOCore
import Subprocess

/// Owns one subprocess generation and the channel used to submit its commands.
struct NodeWorker: Sendable {
    let generation: UUID
    let policy: LaunchPolicy
    var input: (any Channel)?
    private weak var session: REPLSession?
    private let task: Task<Void, Never>
    private var sources = WorkerSourceTable()

    init(configuration: REPLConfiguration, policy: LaunchPolicy, session: REPLSession) {
        let generation = UUID()
        self.generation = generation
        self.policy = policy
        self.session = session
        task = Task { [weak session, eventLoop = session.eventLoop] in
            var channel: (any Channel)?
            let failure: REPLError?
            do {
                try Task.checkCancellation()
                let launch = try policy.makeWorkerLaunch(configuration: configuration)
                if case .external(let url) = configuration.node,
                    !FileManager.default.isExecutableFile(atPath: url.path)
                {
                    throw REPLError.invalidConfiguration("Node executable is missing at \(url.path).")
                }
                let pipes = try await WorkerInput(on: eventLoop)
                channel = pipes.channel
                try Task.checkCancellation()
                var options = PlatformOptions()
                options.createSession = true
                options.teardownSequence = [
                    .send(signal: .kill, toProcessGroup: true, allowedDurationToNextStep: .zero)
                ]
                var environment: [Environment.Key: String] = [:]
                for key in configuration.environment.keys {
                    environment[.init(stringLiteral: key)] = configuration.environment[key]
                }
                _ = try await Subprocess.run(
                    .path(.init(launch.executable.path)), arguments: .init(launch.arguments),
                    environment: .custom(environment), workingDirectory: .init(configuration.workingDirectory.path),
                    platformOptions: options,
                    input: .fileDescriptor(
                        .init(rawValue: pipes.childInput.fileDescriptor), closeAfterSpawningProcess: false),
                    output: .sequence, error: .currentStandardError
                ) { [weak session] execution in
                    defer { try? execution.send(signal: .kill, toProcessGroup: true) }
                    try pipes.childInput.close()
                    try await session?.readWorkerOutput(execution.standardOutput, from: generation, on: pipes.channel)
                }
                failure = nil
            } catch {
                failure = error as? REPLError ?? .workerExited("Node worker failed: \(error.localizedDescription)")
            }
            if let channel {
                try? await channel.close().get()
            }
            if let failure {
                await session?.workerFailed(failure, generation: generation)
            }
        }
    }

    mutating func evaluate(_ request: EvaluationRequest, id: String, directories: [String], startup: WorkerStartup?)
        throws
    {
        let slot = sources.slot(for: request.code)
        if let startup {
            try send(
                .evaluate(
                    executionID: id, code: request.code, metadata: request.metadata,
                    moduleDirectories: directories, startup: startup))
        } else {
            try send(
                WorkerEvaluationFrame(
                    executionID: id, code: request.code, reusing: slot,
                    metadata: request.metadata, moduleDirectories: directories
                )
                .data)
        }
    }

    func send(_ command: WorkerCommand) throws {
        try send(JSONEncoder().encode(command))
    }

    private func send(_ frame: Data) throws {
        var bytes = frame
        guard bytes.count <= REPLSession.maximumFrameBytes else {
            throw REPLError.invalidRequest("Worker command exceeds the configured byte limit.")
        }
        bytes.append(10)
        guard let input else {
            throw REPLError.workerExited("Node worker input is closed.")
        }
        input.writeAndFlush(ByteBuffer(bytes: bytes))
            .whenFailure { [weak session, generation] error in
                Task {
                    await session?
                        .workerFailed(
                            .workerExited("Node worker input failed: \(error.localizedDescription)"),
                            generation: generation)
                }
            }
    }

    /// Returns only after process I/O and all in-flight session callbacks finish.
    func stop() async {
        task.cancel()
        await task.value
    }
}
