/// One-shot acknowledgment owned by the actor driving a test fixture.
enum FixtureAcknowledgment {
    case waiting([CheckedContinuation<Void, Never>])
    case observed

    mutating func register(_ continuation: CheckedContinuation<Void, Never>) {
        switch self {
        case .waiting(var waiters):
            waiters.append(continuation)
            self = .waiting(waiters)
        case .observed:
            continuation.resume()
        }
    }

    mutating func signal() {
        guard case .waiting(let waiters) = self else {
            return
        }
        self = .observed
        for waiter in waiters {
            waiter.resume()
        }
    }
}
