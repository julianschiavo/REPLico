struct RPCEnvelope<Parameters: Decodable>: Decodable {
    let params: Parameters
}
