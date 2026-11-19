import ReplicoKit

actor SuspendedTool: Tool {
    typealias Arguments = NoArguments
    typealias Output = String
    nonisolated let name = "wait"

    private enum State {
        case idle([CheckedContinuation<Void, Never>])
        case entered(CheckedContinuation<ToolResponse<String>, any Error>)
        case cancelled
    }

    private var state: State = .idle([])
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

    func call(arguments: NoArguments, context: ToolContext) async throws -> ToolResponse<String> {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard case .idle(let waiters) = state else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                state = .entered(continuation)
                for waiter in waiters {
                    waiter.resume()
                }
            }
        } onCancel: {
            Task {
                await self.cancel()
            }
        }
    }

    func waitForEntry() async {
        guard case .idle = state else {
            return
        }
        await withCheckedContinuation { continuation in
            if case .idle(var waiters) = state {
                waiters.append(continuation)
                state = .idle(waiters)
            }
        }
    }

    func waitForCancellation() async {
        guard case .cancelled = state else {
            await withCheckedContinuation { continuation in
                cancellationWaiters.append(continuation)
            }
            return
        }
    }

    private func cancel() {
        guard case .entered(let continuation) = state else {
            return
        }
        state = .cancelled
        continuation.resume(throwing: CancellationError())
        for waiter in cancellationWaiters {
            waiter.resume()
        }
        cancellationWaiters.removeAll()
    }
}
