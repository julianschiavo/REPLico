/// An explicitly delegated host capability. Implementations must cooperate with
/// task cancellation and finish any asynchronous cleanup before returning.
/// Calls within an evaluation can run concurrently. A service shared across sessions
/// must also support concurrent calls from those sessions.
public protocol REPLService: Sendable {
    /// The unique name exposed through `nodeRepl.rpc`, captured once when the session is created.
    var name: String {
        get
    }

    /// Handles an execution-scoped JSON request. Cancellation must finish any asynchronous cleanup before returning.
    /// Do not await evaluate, reset, or shutDown on the originating session from this handler:
    /// those operations wait for the current evaluation or its service cleanup to finish.
    func call(_ request: ServiceRequest) async throws -> ServiceResponse
}
