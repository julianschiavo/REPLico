import ReplicoCore

struct EchoService: REPLService {
    let name = "echo"

    func call(_ request: ServiceRequest) async throws -> ServiceResponse {
        ServiceResponse(
            value: .object([
                "payload": request.payload,
                "metadata": .object(request.metadata),
            ]),
            content: [.text("service:")]
        )
    }
}
