@testable import ReplicoKit
import Foundation
import MCP

struct KitTestConnection {
    private struct RemoteFailure: Decodable, Error, LocalizedError {
        let message: String

        var errorDescription: String? {
            message
        }
    }

    private struct Reply<Payload: Decodable>: Decodable {
        let id: JSONValue?
        let result: Payload?
        let error: RemoteFailure?
    }

    private enum Failure: Error {
        case disconnected
        case unexpectedResponse
    }

    private let transport: InMemoryTransport
    private let serving: Task<Void, any Error>
    private var iterator: AsyncThrowingStream<Data, any Error>.Iterator

    static func run(
        application: some ReplicoApplication,
        _ body: (inout Self) async throws -> Void
    ) async throws {
        var connection = try await Self(application: application)
        do {
            try await body(&connection)
        } catch {
            try await connection.close()
            throw error
        }
        try await connection.close()
    }

    private init(application: some ReplicoApplication) async throws {
        let server = try application.makeServer()
        let pair = await InMemoryTransport.createConnectedPair()
        try await pair.server.connect()
        try await pair.client.connect()
        transport = pair.client
        iterator = await pair.client.receive().makeAsyncIterator()
        serving = Task {
            try await server.run(over: pair.server)
        }
        do {
            _ = try await request(
                "initialize",
                parameters: .object([
                    "protocolVersion": .string("2025-11-25"),
                    "clientInfo": .object(["name": .string("FixtureClient"), "version": .string("1")]),
                    "capabilities": .object([:]),
                ]), as: JSONValue.self)
            try await send(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")]))
        } catch {
            await transport.disconnect()
            serving.cancel()
            try? await serving.value
            throw error
        }
    }

    mutating func evaluate(_ code: String, metadata: [String: JSONValue] = [:]) async throws -> CallTool.Result {
        try await request(
            "tools/call",
            parameters: .object([
                "name": .string("js"), "arguments": .object(["code": .string(code)]), "_meta": .object(metadata),
            ]), as: CallTool.Result.self)
    }

    func sendEvaluation(_ code: String, id: String) async throws {
        try await send(
            .object([
                "jsonrpc": .string("2.0"), "id": .string(id), "method": .string("tools/call"),
                "params": .object(["name": .string("js"), "arguments": .object(["code": .string(code)])]),
            ]))
    }

    func cancel(_ id: String) async throws {
        try await send(
            .object([
                "jsonrpc": .string("2.0"), "method": .string("notifications/cancelled"),
                "params": .object(["requestId": .string(id)]),
            ]))
    }

    mutating func reset() async throws {
        _ = try await request(
            "tools/call", parameters: .object(["name": .string("js_reset")]), as: CallTool.Result.self)
    }

    private func close() async throws {
        await transport.disconnect()
        try await serving.value
    }

    private func send(_ message: JSONValue) async throws {
        try await transport.send(JSONEncoder().encode(message))
    }

    private mutating func request<Payload: Decodable>(
        _ method: String, parameters: JSONValue, as type: Payload.Type
    ) async throws -> Payload {
        let id = JSONValue.string(UUID().uuidString)
        try await send(
            .object([
                "jsonrpc": .string("2.0"), "id": id, "method": .string(method), "params": parameters,
            ]))
        guard let message = try await iterator.next() else {
            throw Failure.disconnected
        }
        let response = try JSONDecoder().decode(Reply<Payload>.self, from: message)
        if let error = response.error {
            throw error
        }
        guard response.id == id, let result = response.result else {
            throw Failure.unexpectedResponse
        }
        return result
    }
}
