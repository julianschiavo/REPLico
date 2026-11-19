import ReplicoCore
import ReplicoOptimizations
import MCP

/// A synthesized envelope preserves null error IDs without SDK.ID's coercion.
struct RPCResponse<Payload: Encodable & Sendable>: JSONRPCEnvelope, Sendable {
    let jsonrpc = "2.0"
    let id: JSONValue
    let result: Payload?
    let error: MCPError?

    init(id: JSONValue?, result: Payload) {
        self.id = id ?? .null
        self.result = result
        error = nil
    }

    init(id: JSONValue?, error: MCPError) {
        self.id = id ?? .null
        result = nil
        self.error = error
    }
}
