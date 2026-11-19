struct InitializeParameters: Decodable, Sendable {
    struct ClientInfo: Decodable, Sendable {
        let name: String
        let version: String
    }

    let protocolVersion: String
    let clientInfo: ClientInfo
}
