struct DeadlineInstant: InstantProtocol {
    let offset: Duration

    func advanced(by duration: Duration) -> DeadlineInstant {
        DeadlineInstant(offset: offset + duration)
    }

    func duration(to other: DeadlineInstant) -> Duration {
        other.offset - offset
    }

    static func < (lhs: DeadlineInstant, rhs: DeadlineInstant) -> Bool {
        lhs.offset < rhs.offset
    }
}
