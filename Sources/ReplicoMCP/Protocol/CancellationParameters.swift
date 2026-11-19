import ReplicoCore

struct CancellationParameters: Decodable, Sendable {
    let requestID: JSONValue
    let reason: String?

    private enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case reason
    }
}
