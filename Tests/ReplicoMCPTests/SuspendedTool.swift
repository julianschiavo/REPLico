import ReplicoMCP
import MCP

actor SuspendedTool: ReplicoMCP.Tool {
    struct Arguments: Decodable, Sendable {
    }

    private enum State {
        case waiting(CheckedContinuation<Void, Never>?)
        case running(CheckedContinuation<CallTool.Result, any Error>, CheckedContinuation<Void, Never>?)
        case cancelled
    }

    nonisolated let definition = MCP.Tool(
        name: "suspend",
        description: "Wait for client cancellation.",
        inputSchema: ["type": "object", "additionalProperties": false]
    )
    private var state: State = .waiting(nil)

    func call(arguments: Arguments, context: ToolCallContext) async throws -> CallTool.Result {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard case .waiting(let observer) = state else {
                    preconditionFailure("The fixture accepts one call.")
                }
                state = .running(continuation, nil)
                observer?.resume()
            }
        } onCancel: {
            Task {
                await self.cancel()
            }
        }
    }

    func waitForEntry() async {
        if case .waiting = state {
            await withCheckedContinuation { observer in
                state = .waiting(observer)
            }
        }
    }

    func waitForCancellation() async {
        if case .running(let invocation, _) = state {
            await withCheckedContinuation { observer in
                state = .running(invocation, observer)
            }
        }
    }

    private func cancel() {
        guard case .running(let invocation, let observer) = state else {
            return
        }
        state = .cancelled
        invocation.resume(throwing: CancellationError())
        observer?.resume()
    }
}
