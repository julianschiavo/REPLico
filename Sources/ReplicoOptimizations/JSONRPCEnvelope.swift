import MCP

/// Exposes the four canonical envelope fields to `MCPResponseEncoder`.
///
/// Foundation needs only `Encodable`. The optimized encoder additionally inspects these
/// fields to select a fixed tool-result wire format. Conforming values must encode exactly
/// `jsonrpc`, `id`, and any nonnil `result` or `error`, using these property names.
///
/// Foundation:
/// ```swift
/// let data = try JSONEncoder().encode(response)
/// ```
///
/// Optimized, after making the envelope conform to this protocol:
/// ```swift
/// let data = try MCPResponseEncoder().encode(response)
/// ```
package protocol JSONRPCEnvelope: Encodable {
    /// The request identifier's concrete encodable representation.
    associatedtype Identifier: Encodable
    /// The successful response payload's concrete type.
    associatedtype Payload: Encodable

    /// The JSON-RPC protocol version, normally `2.0`.
    var jsonrpc: String {
        get
    }
    /// The identifier, including an explicit JSON null for unowned errors.
    var id: Identifier {
        get
    }
    /// The successful payload, absent for an error response.
    var result: Payload? {
        get
    }
    /// The protocol error, absent for a successful response.
    var error: MCPError? {
        get
    }
}
