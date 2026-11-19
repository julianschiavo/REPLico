import ReplicoCore
import ReplicoOptimizations
import Foundation
import MCP
import NIOCore

/// Owns one MCP connection and its persistent JavaScript session.
public actor ReplicoServer {
    /// Handles protocol messages on the same executor as the session's worker pipe.
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        session.unownedExecutor
    }

    nonisolated var eventLoop: any EventLoop {
        session.eventLoop
    }

    private enum State {
        case idle
        case awaitingInitialize
        case awaitingInitialized(HostIntegration)
        case ready(HostIntegration)
        case failed(any Error)
        case stopped
    }

    private let session: REPLSession
    private let serverInfo: Info
    private let tools: [RegisteredTool]
    private let environment: [String: String]
    private var state: State = .idle
    private var bufferedFrames = 0
    private var requests: [JSONValue: Task<Void, Never>] = [:]
    private var decodedCalls = DecodedCallCache<MCPToolCall>()
    private var responseEncoder = MCPResponseEncoder()

    /// Creates a server with the standard REPL tools or an explicit ordered registry.
    ///
    /// Pass an empty array to expose no tools. Empty or duplicate names throw
    /// ``ToolRegistrationError`` before the connection opens.
    ///
    /// The server advertises `serverInfo` to clients. It defaults to the hosting executable.
    /// The environment is used by the MCP integration to select launch policy.
    public init(
        session: REPLSession,
        serverInfo: Info = ReplicoServer.hostInfo,
        tools: [any Tool]? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        let actions =
            tools ?? [
                JavaScriptTool(session: session),
                ResetTool(session: session),
                AddNodeModuleDirectoryTool(session: session),
            ]
        let registry = actions.map(RegisteredTool.init)
        var names: Set<String> = []
        for tool in registry {
            guard !tool.definition.name.isEmpty else {
                throw ToolRegistrationError.emptyName
            }
            guard names.insert(tool.definition.name).inserted else {
                throw ToolRegistrationError.duplicateName(tool.definition.name)
            }
        }
        self.session = session
        self.serverInfo = serverInfo
        self.tools = registry
        self.environment = environment
    }

    /// Serves once until EOF or cancellation, then cancels and drains admitted calls.
    ///
    /// The server closes the session and transport before returning. Custom tools
    /// must cooperate with cancellation so their admitted calls can finish draining.
    public func run(over transport: any Transport) async throws {
        guard case .idle = state else {
            throw MCPError.invalidRequest("A Replico server can run only once.")
        }
        state = .awaitingInitialize
        do {
            try await transport.connect()
            for try await data in await transport.receive() {
                try Task.checkCancellation()
                try await receive(data, transport: transport)
                if bufferedFrames > 0 {
                    bufferedFrames -= 1
                }
            }
        } catch MCPError.connectionClosed {
            // The SDK's in-memory transport represents peer EOF with this error.
        } catch {
            state = .failed(error)
        }
        let terminalState = state
        await finish(over: transport)
        if case .failed(let error) = terminalState {
            throw error
        }
    }

    private func finish(over transport: any Transport) async {
        state = .stopped
        let admitted = Array(requests.values)
        for task in admitted {
            task.cancel()
        }
        await session.shutDown()
        for task in admitted {
            await task.value
        }
        requests.removeAll()
        decodedCalls = .init()
        responseEncoder = .init()
        await transport.disconnect()
    }

    /// Serves the connection over standard input and standard output.
    public func runUsingStandardIO() async throws {
        try await run(over: StandardIOTransport(server: self))
    }

    /// Accepts a complete tools/call frame on the shared pipe executor. Frames that
    /// need protocol dispatch keep their place in the transport's receive stream.
    func admitFromStandardIO(_ frame: Data, transport: StandardIOTransport) -> Bool {
        if bufferedFrames == 0, requests.isEmpty, case .ready(let integration) = state,
            let header = CanonicalToolCallHeader(frame: frame, reusing: decodedCalls.latestHeader),
            let id = MessageHeader(toolCallID: header.id).requestID
        {
            do {
                try admitCall(id: id, data: frame, canonical: header, integration: integration, transport: transport)
                return true
            } catch {
                // The regular dispatcher sends the protocol error in receive order.
            }
        }
        bufferedFrames += 1
        return false
    }

    private func receive(_ data: Data, transport: any Transport) async throws {
        let header: MessageHeader
        let canonical = CanonicalToolCallHeader(frame: data, reusing: decodedCalls.latestHeader)
        do {
            if let canonical {
                header = MessageHeader(toolCallID: canonical.id)
            } else {
                // Foundation decodes ignored fields lazily, so validate the entire frame first.
                _ = try JSONDocument(validating: data)
                header = try JSONDecoder().decode(MessageHeader.self, from: data)
            }
        } catch DecodingError.typeMismatch(_, let context) where context.codingPath.isEmpty,
            DecodingError.valueNotFound(_, let context) where context.codingPath.isEmpty
        {
            await send(
                RPCResponse<MCP.Empty>(id: nil, error: .invalidRequest("An MCP message must be an object.")),
                transport: transport)
            return
        } catch {
            await send(RPCResponse<MCP.Empty>(id: nil, error: .parseError("Invalid JSON.")), transport: transport)
            return
        }
        var id: JSONValue?
        do {
            if let candidate = header.requestID {
                switch candidate {
                case .string, .integer, .unsignedInteger:
                    id = candidate
                default:
                    throw MCPError.invalidRequest("Request IDs must be strings or integers.")
                }
            }
            guard let methodName = header.method else {
                throw MCPError.invalidRequest("Invalid MCP request.")
            }
            guard header.version == "2.0" else {
                throw MCPError.invalidRequest("jsonrpc must be 2.0.")
            }
            guard let id else {
                if let method = NotificationMethod(rawValue: methodName) {
                    receiveNotification(method, data: data)
                }
                return
            }
            guard requests[id] == nil else {
                throw MCPError.invalidRequest("A request with this ID is already running.")
            }
            guard let method = RequestMethod(rawValue: methodName) else {
                throw MCPError.methodNotFound("Unknown method: \(methodName).")
            }
            try await dispatch(method, id: id, data: data, canonical: canonical, transport: transport)
        } catch let error as MCPError {
            await send(RPCResponse<MCP.Empty>(id: id, error: error), transport: transport)
        }
    }

    private func dispatch(
        _ method: RequestMethod, id: JSONValue, data: Data, canonical: CanonicalToolCallHeader?,
        transport: any Transport
    ) async throws {
        switch method {
        case .initialize:
            guard case .awaitingInitialize = state else {
                throw MCPError.invalidRequest("This connection is already initialized.")
            }
            let parameters = try decode(InitializeParameters.self, from: data)
            state = .awaitingInitialized(
                HostIntegration(
                    clientName: parameters.clientInfo.name, environment: environment
                ))
            let version =
                ["2025-11-25", "2025-06-18"].contains(parameters.protocolVersion)
                ? parameters.protocolVersion : "2025-11-25"
            let result = InitializeResponse(protocolVersion: version, serverInfo: serverInfo)
            await send(RPCResponse(id: id, result: result), transport: transport)
        case .ping:
            await send(RPCResponse(id: id, result: MCP.Empty()), transport: transport)
        case .listTools:
            guard case .ready = state else {
                throw MCPError.invalidRequest("Initialize the MCP connection before using tools.")
            }
            await send(
                RPCResponse(id: id, result: ListTools.Result(tools: tools.map(\.definition))), transport: transport)
        case .callTool:
            guard case .ready(let integration) = state else {
                throw MCPError.invalidRequest("Initialize the MCP connection before using tools.")
            }
            try admitCall(id: id, data: data, canonical: canonical, integration: integration, transport: transport)
        }
    }

    private func admitCall(
        id: JSONValue, data: Data, canonical: CanonicalToolCallHeader?,
        integration: HostIntegration, transport: any Transport
    ) throws {
        let admitted: MCPToolCall
        if let canonical, let cached = decodedCalls[canonical.parameters] {
            admitted = cached
        } else {
            admitted = try JSONDecoder().decode(MCPToolCall.self, from: data, configuration: tools)
            if admitted.metadata.isEmpty, admitted.invocation is PreparedToolInvocation<JavaScriptTool> {
                if let canonical {
                    decodedCalls.remember(admitted, for: canonical)
                }
            } else {
                decodedCalls = .init()
            }
        }
        requests[id] = Task {
            await call(admitted, id: id, integration: integration, transport: transport)
        }
    }

    private func receiveNotification(_ method: NotificationMethod, data: Data) {
        switch method {
        case .initialized:
            guard case .awaitingInitialized(let integration) = state else {
                return
            }
            state = .ready(integration)
        case .cancelled:
            guard let parameters = try? decode(CancellationParameters.self, from: data) else {
                return
            }
            requests[parameters.requestID]?.cancel()
        }
    }

    private func call(
        _ request: MCPToolCall,
        id: JSONValue,
        integration: HostIntegration,
        transport: any Transport
    ) async {
        defer {
            requests.removeValue(forKey: id)
        }
        do {
            try Task.checkCancellation()
            let metadata = request.metadata
            let result = try await request.invocation.invoke(
                context: ToolCallContext(metadata: metadata, launchPolicy: integration.launchPolicy(for: metadata))
            )
            try Task.checkCancellation()
            await send(RPCResponse(id: id, result: result), transport: transport)
        } catch is CancellationError {
            decodedCalls = .init()
            return
        } catch {
            decodedCalls = .init()
            guard !Task.isCancelled else {
                return
            }
            await send(
                RPCResponse<MCP.Empty>(
                    id: id, error: error as? MCPError ?? .internalError(error.localizedDescription)
                ), transport: transport)
        }
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do {
            return try JSONDecoder().decode(RPCEnvelope<Value>.self, from: data).params
        } catch {
            throw MCPError.invalidParams("Invalid method parameters: \(error.localizedDescription)")
        }
    }

    private func send<Payload>(_ response: RPCResponse<Payload>, transport: any Transport) async {
        do {
            if let pipe = transport as? StandardIOTransport, let frame = try responseEncoder.frame(for: response) {
                switch frame {
                case .contiguous(let bytes):
                    try await pipe.send(bytes, after: nil)
                case .segments(let header, let body):
                    try await pipe.send(body, after: header)
                }
            } else {
                try await transport.send(MCPResponseEncoder().encode(response))
            }
        } catch {
            state = .failed(error)
            await transport.disconnect()
        }
    }
}
