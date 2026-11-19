/// Forwards an owned service value into the worker frame's encoder without a JSON tree conversion.
struct ServiceValue: Encodable, Sendable {
    let value: any Encodable & Sendable

    func encode(to encoder: any Encoder) throws {
        try value.encode(to: encoder)
    }
}
