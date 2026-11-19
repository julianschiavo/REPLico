import ReplicoCore

/// Suspends one service call until the test releases it or its evaluation is cancelled.
actor BarrierService: REPLService {
    nonisolated let name = "barrier"

    private enum State {
        case idle
        case running(CheckedContinuation<ServiceResponse, any Error>)
        case cancelling(CheckedContinuation<ServiceResponse, any Error>)
        case finished
    }

    private let holdsCleanup: Bool
    private var state: State = .idle
    private var entry: FixtureAcknowledgment = .waiting([])
    private var cancellation: FixtureAcknowledgment = .waiting([])

    init(holdsCleanup: Bool = false) {
        self.holdsCleanup = holdsCleanup
    }

    func call(_ request: ServiceRequest) async throws -> ServiceResponse {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard case .idle = state else {
                    continuation.resume(throwing: REPLError.invalidRequest("Barrier service can be called only once."))
                    return
                }
                state = .running(continuation)
                entry.signal()
            }
        } onCancel: {
            Task {
                await self.cancel()
            }
        }
    }

    func waitForEntry() async {
        await withCheckedContinuation { entry.register($0) }
    }

    func waitForCancellation() async {
        await withCheckedContinuation { cancellation.register($0) }
    }

    func release() {
        switch state {
        case .running(let continuation):
            state = .finished
            continuation.resume(returning: ServiceResponse(value: .string("released")))
        case .cancelling(let continuation):
            state = .finished
            continuation.resume(throwing: CancellationError())
        case .idle, .finished:
            break
        }
    }

    private func cancel() {
        if case .running(let continuation) = state {
            state = .cancelling(continuation)
            if !holdsCleanup {
                release()
            }
        }
        cancellation.signal()
    }
}
