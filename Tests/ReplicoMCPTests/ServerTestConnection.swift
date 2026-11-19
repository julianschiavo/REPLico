import ReplicoMCP
import ReplicoCore
import Foundation
import MCP

struct ServerTestConnection {
    private enum Failure: Error {
        case disconnected
    }

    private let transport: InMemoryTransport
    private let serverTask: Task<Void, any Error>
    private var iterator: AsyncThrowingStream<Data, any Error>.Iterator

    static func run(
        tools: [any ReplicoMCP.Tool]? = nil,
        _ body: (inout Self) async throws -> Void
    ) async throws {
        var connection = try await Self(tools: tools)
        do {
            try await body(&connection)
        } catch {
            try await connection.close()
            throw error
        }
        try await connection.close()
    }

    private init(tools: [any ReplicoMCP.Tool]?) async throws {
        let pair = await InMemoryTransport.createConnectedPair()
        try await pair.server.connect()
        try await pair.client.connect()
        let session = try REPLSession(
            configuration: REPLConfiguration(
                nodeExecutable: URL(filePath: "/usr/bin/false"),
                environment: [:]
            ))
        let server = try ReplicoServer(session: session, tools: tools, environment: [:])
        transport = pair.client
        iterator = await pair.client.receive().makeAsyncIterator()
        serverTask = Task {
            try await server.run(over: pair.server)
        }
    }

    func send(_ value: JSONValue) async throws {
        try await transport.send(JSONEncoder().encode(value))
    }

    mutating func request(_ value: JSONValue) async throws -> JSONValue {
        try await send(value)
        return try await receive()
    }

    mutating func request(_ source: String) async throws -> JSONValue {
        try await transport.send(Data(source.utf8))
        return try await receive()
    }

    mutating func receive() async throws -> JSONValue {
        guard let data = try await iterator.next() else {
            throw Failure.disconnected
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    mutating func initialize(
        id: JSONValue = .integer(1),
        version: String = "2025-11-25",
        clientName: String = "ReplicoTests"
    ) async throws -> JSONValue {
        let response = try await request(
            .object([
                "jsonrpc": .string("2.0"),
                "id": id,
                "method": .string("initialize"),
                "params": .object([
                    "protocolVersion": .string(version),
                    "clientInfo": .object([
                        "name": .string(clientName),
                        "version": .string("1.0.0"),
                    ]),
                    "capabilities": .object([:]),
                ]),
            ]))
        try await send(
            .object([
                "jsonrpc": .string("2.0"),
                "method": .string("notifications/initialized"),
            ]))
        return response
    }

    private func close() async throws {
        await transport.disconnect()
        try await serverTask.value
    }
}
