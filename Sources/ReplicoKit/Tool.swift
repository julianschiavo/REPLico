import ReplicoCore

/// A typed host capability exposed as an asynchronous JavaScript method.
///
/// Calls can run concurrently. Implementations must cooperate with cancellation and
/// complete asynchronous cleanup before returning. A tool must not await evaluation,
/// reset, or shutdown of its own originating session, which waits for that tool to finish.
public protocol Tool: Sendable {
    /// The concrete arguments decoded directly from the original JSON request bytes.
    associatedtype Arguments: ToolArgumentsProtocol
    /// The value encoded for the JavaScript Promise result.
    associatedtype Output: Encodable & Sendable

    /// The method name, captured once when the tool's group is created.
    var name: String {
        get
    }

    /// Discovery text, captured once when the tool's group is created.
    var description: String {
        get
    }

    /// Executes one call with immutable metadata and execution identity.
    func call(arguments: Arguments, context: ToolContext) async throws -> ToolResponse<Output>
}

extension Tool {
    /// Empty discovery text for tools that do not supply a description.
    public var description: String {
        ""
    }

    func invoke(_ request: ServiceRequest) async throws -> ServiceResponse {
        let arguments = try request.decode(Arguments.self)
        let response = try await call(
            arguments: arguments,
            context: ToolContext(executionID: request.executionID, metadata: request.metadata)
        )
        return ServiceResponse(value: response.value, content: response.content)
    }
}
