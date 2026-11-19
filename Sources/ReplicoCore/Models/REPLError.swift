import Foundation

/// Configuration, lifecycle and worker protocol failures reported by the runtime.
public enum REPLError: Error, Sendable, Equatable, LocalizedError {
    /// The worker configuration or required sandbox authority is unavailable.
    case invalidConfiguration(String)
    /// A request violates an input or execution rule.
    case invalidRequest(String)
    /// Worker framing, content or output limits were violated.
    case protocolViolation(String)
    /// The worker failed or exited before completing its work.
    case workerExited(String)
    /// The evaluation deadline expired and kernel state was cleared.
    case timedOut
    /// A reset interrupted the evaluation.
    case reset
    /// The session has shut down permanently.
    case closed

    /// A human-readable description of the failure.
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message), .invalidRequest(let message),
            .protocolViolation(let message), .workerExited(let message):
            return message
        case .timedOut:
            return "JavaScript execution timed out; kernel reset."
        case .reset:
            return "JavaScript execution was reset."
        case .closed:
            return "The REPL session is closed."
        }
    }
}
