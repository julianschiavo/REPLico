// A deterministic one-shot deadline gate. Tests explicitly fire a registered
// deadline; they never wait for wall-clock time or poll the worker.
actor DeadlineClock: Clock {
    nonisolated let now = DeadlineInstant(offset: .zero)
    nonisolated let minimumResolution: Duration = .nanoseconds(1)

    private enum Deadline {
        case idle
        case suspended(DeadlineInstant, CheckedContinuation<Void, any Error>)
    }

    private var registration: FixtureAcknowledgment = .waiting([])
    private var deadline: Deadline = .idle

    func sleep(until instant: DeadlineInstant, tolerance: Duration?) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                deadline = .suspended(instant, continuation)
                registration.signal()
            }
        } onCancel: {
            Task {
                await self.cancelDeadline()
            }
        }
    }

    var scheduledInstant: DeadlineInstant? {
        guard case .suspended(let instant, _) = deadline else {
            return nil
        }
        return instant
    }

    func waitForRegistration() async {
        await withCheckedContinuation { registration.register($0) }
    }

    func fire() {
        if case .suspended(_, let continuation) = deadline {
            deadline = .idle
            continuation.resume()
        }
    }

    private func cancelDeadline() {
        if case .suspended(_, let continuation) = deadline {
            deadline = .idle
            continuation.resume(throwing: CancellationError())
        }
    }
}
