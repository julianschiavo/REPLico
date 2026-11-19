import ReplicoOptimizations
import Foundation
import NIOCore
import NIOPosix

/// A persistent JavaScript session that serializes evaluations and owns its worker process.
///
/// The embedding caller must await `shutDown()` when finished, including error and
/// cancellation paths. Releasing the session does not perform asynchronous cleanup.
///
/// Cancelling a queued evaluation removes only that request. Cancelling an active evaluation
/// stops the worker, cancels its host services, and awaits their cleanup before starting another
/// evaluation. Services that do not cooperate with cancellation can delay that cleanup.
public actor REPLSession {
    /// The process-wide event loop shared by worker I/O and session state transitions.
    package nonisolated let eventLoop: any EventLoop = MultiThreadedEventLoopGroup.singleton.next()

    /// Schedules session state transitions on the event loop that reads worker frames.
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        eventLoop.executor.asUnownedSerialExecutor()
    }

    private struct PendingEvaluation {
        let id: String
        let request: EvaluationRequest
        let continuation: CheckedContinuation<EvaluationResult, any Error>
    }

    private struct EvaluationOutput {
        let limit: Int
        private(set) var content: [REPLContent] = []
        private(set) var byteCount = 0
        private var namedItems: [String: Int] = [:]
        private var lastUnnamedItem: Int?

        mutating func append(_ item: REPLContent, itemID: String? = nil) throws {
            switch item {
            case .text(let text):
                byteCount += text.utf8.count
            case .image(let data, _):
                byteCount += data.count
            }
            guard byteCount <= limit else {
                throw REPLError.protocolViolation("Execution output exceeds the configured byte limit.")
            }
            if case .text(let text) = item {
                if let itemID, let index = namedItems[itemID], case .text(let previous) = content[index] {
                    content[index] = .text(previous + text)
                    return
                }
                if itemID == nil, let index = lastUnnamedItem,
                    index == content.count - 1, case .text(let previous) = content[index]
                {
                    content[index] = .text(previous + text)
                    return
                }
                if let itemID {
                    namedItems[itemID] = content.count
                }
            }
            lastUnnamedItem = itemID == nil && item.isText ? content.count : nil
            content.append(item)
        }

        mutating func appendDiagnostic(_ message: String) {
            // Final JavaScript diagnostics remain visible even when ordinary output fills the budget.
            content.append(.text(message))
        }
    }

    private enum Deadline {
        case eventLoop(Scheduled<Void>)
        case clock(Task<Void, Never>)

        func cancel() {
            switch self {
            case .eventLoop(let timer):
                timer.cancel()
            case .clock(let timer):
                timer.cancel()
            }
        }
    }

    private enum Phase {
        case starting(NodeWorker, Deadline)
        case evaluating(NodeWorker, Deadline)

        var worker: NodeWorker {
            switch self {
            case .starting(let worker, _), .evaluating(let worker, _):
                return worker
            }
        }

        var deadline: Deadline {
            switch self {
            case .starting(_, let task), .evaluating(_, let task):
                return task
            }
        }
    }

    private struct Execution {
        let pending: PendingEvaluation
        var phase: Phase
        var output: EvaluationOutput
        var serviceTasks: [String: Task<Void, Never>] = [:]
    }

    private enum StopBehavior: Comparable {
        case restart
        case reset
        case shutDown
    }

    private enum AuthorityRequirement {
        case hostAllowed
        case sandboxRequired
    }

    private enum State {
        case idle(NodeWorker?)
        case executing(Execution)
        case stopping(Task<Void, Never>, StopBehavior)
        case closed

        var worker: NodeWorker? {
            switch self {
            case .idle(let worker):
                return worker
            case .executing(let execution):
                return execution.phase.worker
            case .stopping, .closed:
                return nil
            }
        }

        var acceptsEvaluations: Bool {
            switch self {
            case .closed, .stopping(_, .shutDown):
                return false
            default:
                return true
            }
        }
    }

    private let configuration: REPLConfiguration
    private let services: [String: any REPLService]
    private let clock: any Clock<Duration>
    private let startupSource: String
    private var state: State = .idle(nil)
    private var textSnapshot: WorkerTextSnapshot?
    private var queue: [PendingEvaluation] = []
    private var moduleDirectories: [String] = []
    private var authorityRequirement: AuthorityRequirement = .hostAllowed

    /// Creates a lazy session with a fixed service allowlist.
    ///
    /// Service names are captured once during registration. `clock` controls evaluation
    /// timeouts; worker startup uses a separate continuous clock. Trusted `startupSource`
    /// runs once as a module in each fresh kernel before user code, including after reset.
    /// Use `globalThis` to install values shared with cells. Initialization uses the first
    /// evaluation's timeout. Throws for invalid output
    /// limits or service names that are empty, longer than 256 UTF-8 bytes, or repeated.
    public init(
        configuration: REPLConfiguration,
        services: [any REPLService] = [],
        startupSource: String = "",
        clock: any Clock<Duration> = ContinuousClock()
    ) throws {
        guard configuration.maximumOutputBytes > 0 else {
            throw REPLError.invalidConfiguration("Protocol and output limits must be positive.")
        }
        var registered: [String: any REPLService] = [:]
        for service in services {
            let name = service.name
            guard !name.isEmpty, name.utf8.count <= 256, registered[name] == nil else {
                throw REPLError.invalidConfiguration("Service names must be nonempty and unique.")
            }
            registered[name] = service
        }
        self.configuration = configuration
        self.services = registered
        self.startupSource = startupSource
        self.clock = clock
    }

    /// Evaluates a cell in submission order and collects its text and validated images.
    ///
    /// JavaScript and tracked-helper failures return a result with `didFail` set. Active
    /// cancellation, timeouts, and worker failures throw after worker and service cleanup,
    /// clearing JavaScript state. Queue time and worker startup do not consume `request.timeout`.
    public func evaluate(_ request: EvaluationRequest) async throws -> EvaluationResult {
        guard request.timeout > .zero, request.code.utf8.count <= 1_024 * 1_024 else {
            throw REPLError.invalidRequest("Code must fit within 1 MiB and the timeout must be positive.")
        }
        let id = UUID().uuidString
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                enqueue(PendingEvaluation(id: id, request: request, continuation: continuation))
            }
        } onCancel: {
            Task {
                await self.interrupt(id, reason: CancellationError())
            }
        }
    }

    /// Adds an absolute file URL ending in `node_modules` to package search directories.
    ///
    /// The directory may be missing when registered. Standardized paths are deduplicated,
    /// and registration survives reset. Throws if the URL is invalid or shutdown has begun.
    public func addNodeModuleDirectory(at directory: URL) throws {
        guard state.acceptsEvaluations else {
            throw REPLError.closed
        }
        guard directory.isFileURL, directory.path.hasPrefix("/"),
            directory.lastPathComponent == "node_modules"
        else {
            throw REPLError.invalidRequest("Provide an absolute node_modules file URL.")
        }
        let path = directory.standardizedFileURL.path
        if !moduleDirectories.contains(path) {
            moduleDirectories.append(path)
        }
    }

    /// Cancels active and queued evaluations, awaits cleanup, and clears JavaScript state.
    /// Registered module directories and the requirement to use a sandbox are preserved.
    public func reset() async {
        await beginStop(reason: REPLError.reset, behavior: .reset)?.value
    }

    /// Permanently closes the session, cancelling evaluations and awaiting worker and service cleanup.
    /// Further evaluations and module-directory registrations fail as soon as shutdown begins.
    public func shutDown() async {
        await beginStop(reason: REPLError.closed, behavior: .shutDown)?.value
    }

    private func enqueue(_ pending: PendingEvaluation) {
        guard state.acceptsEvaluations else {
            pending.continuation.resume(throwing: REPLError.closed)
            return
        }
        queue.append(pending)
        startNext()
    }

    private func startNext() {
        while case .idle(let existing) = state, let pending = queue.first {
            do {
                let request = pending.request
                switch request.launchPolicy {
                case .direct:
                    guard case .hostAllowed = authorityRequirement else {
                        throw REPLError.invalidConfiguration("This session requires a sandbox launch policy.")
                    }
                case .sandboxed:
                    authorityRequirement = .sandboxRequired
                case .unavailable(let error):
                    authorityRequirement = .sandboxRequired
                    throw error
                }
                if let existing, existing.policy != request.launchPolicy {
                    _ = beginStop(reason: REPLError.reset, behavior: .restart)
                    return
                }
                var worker =
                    try existing
                    ?? NodeWorker(configuration: configuration, policy: request.launchPolicy, session: self)
                let phase: Phase
                if existing == nil {
                    phase = .starting(
                        worker,
                        scheduleTimeout(
                            for: pending.id, after: .seconds(120), clock: ContinuousClock(),
                            reason: .workerExited("Node worker startup timed out; kernel reset.")
                        ))
                } else {
                    try worker.evaluate(request, id: pending.id, directories: moduleDirectories, startup: nil)
                    phase = .evaluating(
                        worker,
                        scheduleTimeout(
                            for: pending.id, after: request.timeout, clock: clock, reason: .timedOut
                        ))
                }
                queue.removeFirst()
                state = .executing(
                    Execution(
                        pending: pending, phase: phase,
                        output: EvaluationOutput(limit: configuration.maximumOutputBytes)
                    ))
            } catch {
                if case .executing = state {
                    _ = beginStop(reason: error, behavior: .restart)
                    return
                }
                queue.removeFirst()
                _ = beginStop(reason: error, behavior: .restart, completing: pending)
            }
        }
    }

    private func scheduleTimeout(
        for executionID: String, after duration: Duration, clock: any Clock<Duration>, reason: REPLError
    ) -> Deadline {
        if clock is ContinuousClock {
            return .eventLoop(
                eventLoop.scheduleTask(in: TimeAmount(duration)) {
                    self.assumeIsolated { $0.interrupt(executionID, reason: reason) }
                })
        }
        return .clock(
            Task {
                do {
                    try await clock.sleep(for: duration)
                    self.interrupt(executionID, reason: reason)
                } catch {
                    return
                }
            })
    }

    private func interrupt(_ id: String, reason: any Error) {
        if let index = queue.firstIndex(where: { $0.id == id }) {
            queue.remove(at: index).continuation.resume(throwing: reason)
        } else if case .executing(let execution) = state, execution.pending.id == id {
            _ = beginStop(reason: reason, behavior: .restart)
        }
    }

    private func beginStop(
        reason: any Error, behavior: StopBehavior, completing: PendingEvaluation? = nil
    ) -> Task<Void, Never>? {
        if behavior >= .reset {
            for pending in queue {
                pending.continuation.resume(throwing: reason)
            }
            queue.removeAll()
        }
        let worker = state.worker
        textSnapshot = nil
        let execution: Execution?
        switch state {
        case .closed:
            return nil
        case .stopping(let task, let currentBehavior):
            state = .stopping(task, max(currentBehavior, behavior))
            return task
        case .executing(let active):
            execution = active
            active.phase.deadline.cancel()
            for task in active.serviceTasks.values {
                task.cancel()
            }
        case .idle:
            execution = nil
        }
        let task = Task {
            await worker?.stop()
            if let execution {
                for serviceTask in execution.serviceTasks.values {
                    await serviceTask.value
                }
                execution.pending.continuation.resume(throwing: reason)
            }
            completing?.continuation.resume(throwing: reason)
            guard case .stopping(_, let finalBehavior) = self.state else {
                return
            }
            self.state = finalBehavior == .shutDown ? .closed : .idle(nil)
            self.startNext()
        }
        state = .stopping(task, behavior)
        return task
    }

    func handle(_ event: WorkerEvent, frame: Data, from generation: UUID, on channel: any Channel) {
        guard state.worker?.generation == generation else {
            return
        }
        do {
            if case .executing(let execution) = state, case .starting = execution.phase {
                switch event {
                case .ready, .fatal:
                    break
                default:
                    throw REPLError.protocolViolation("Worker emitted an execution event before startup completed.")
                }
            }
            switch event {
            case .ready(let version, let nodeVersion):
                guard version == 1, nodeVersion == "26.13.1" else {
                    throw REPLError.protocolViolation("Worker handshake requires protocol 1 and Node 26.13.1.")
                }
                guard case .executing(var execution) = state, case .starting(var worker, _) = execution.phase else {
                    throw REPLError.protocolViolation("Worker announced readiness outside startup.")
                }
                execution.phase.deadline.cancel()
                worker.input = channel
                try worker.evaluate(
                    execution.pending.request, id: execution.pending.id, directories: moduleDirectories,
                    startup: WorkerStartup(
                        configuration: configuration, startupSource: startupSource, serviceNames: services.keys.sorted()
                    )
                )
                execution.phase = .evaluating(
                    worker,
                    scheduleTimeout(
                        for: execution.pending.id, after: execution.pending.request.timeout, clock: clock,
                        reason: .timedOut
                    ))
                state = .executing(execution)
            case .output(let id, let content):
                guard var execution = activeExecution(for: id) else {
                    return
                }
                let item = try content.validatedContent(
                    snapshot: &textSnapshot, remainingBytes: execution.output.limit - execution.output.byteCount)
                try execution.output.append(item, itemID: content.itemID)
                state = .executing(execution)
            case .service(let id, let requestID, let name, let payload):
                guard var execution = activeExecution(for: id) else {
                    return
                }
                guard execution.serviceTasks[requestID] == nil else {
                    throw REPLError.protocolViolation("Duplicate service request ID.")
                }
                let invocation = ServiceRequest(
                    executionID: id, payload: payload, metadata: execution.pending.request.metadata, frame: frame
                )
                let handler = services[name]
                execution.serviceTasks[requestID] = Task {
                    do {
                        guard let handler else {
                            throw REPLError.invalidRequest("Service is not registered: \(name).")
                        }
                        let response = try await handler.call(invocation)
                        self.reply(requestID, executionID: id, value: response.value, content: response.content)
                    } catch {
                        self.reply(requestID, executionID: id, error: error.localizedDescription)
                    }
                }
                state = .executing(execution)
            case .completed(let id, let succeeded, let failure):
                guard var execution = activeExecution(for: id) else {
                    return
                }
                guard execution.serviceTasks.isEmpty else {
                    throw REPLError.protocolViolation("Worker completed while host service calls were still active.")
                }
                execution.phase.deadline.cancel()
                if !succeeded {
                    execution.output.appendDiagnostic(failure?.message ?? "JavaScript execution failed.")
                }
                state = .idle(execution.phase.worker)
                execution.pending.continuation.resume(
                    returning: EvaluationResult(content: execution.output.content, didFail: !succeeded))
                startNext()
            case .fatal(_, let failure):
                throw REPLError.workerExited(failure.message)
            }
        } catch {
            _ = beginStop(reason: error, behavior: .restart)
        }
    }

    private func activeExecution(for id: String) -> Execution? {
        guard case .executing(let execution) = state, case .evaluating = execution.phase,
            execution.pending.id == id
        else {
            return nil
        }
        return execution
    }

    func workerFailed(_ error: REPLError, generation: UUID) {
        guard state.worker?.generation == generation else {
            return
        }
        _ = beginStop(reason: error, behavior: .restart)
    }

    private func reply(
        _ requestID: String, executionID: String,
        value: any Encodable & Sendable = JSONValue.null, content: [REPLContent] = [], error: String? = nil
    ) {
        guard case .executing(var execution) = state, execution.pending.id == executionID,
            execution.serviceTasks.removeValue(forKey: requestID) != nil
        else {
            return
        }
        do {
            for item in content {
                try execution.output.append(item)
            }
            state = .executing(execution)
            do {
                try execution.phase.worker.send(
                    .serviceReply(
                        executionID: executionID, requestID: requestID, ok: error == nil,
                        value: ServiceValue(value: value), error: error
                    ))
            } catch {
                try execution.phase.worker.send(
                    .serviceReply(
                        executionID: executionID, requestID: requestID, ok: false,
                        value: ServiceValue(value: JSONValue.null), error: error.localizedDescription
                    ))
            }
        } catch {
            _ = beginStop(reason: error, behavior: .restart)
        }
    }
}
