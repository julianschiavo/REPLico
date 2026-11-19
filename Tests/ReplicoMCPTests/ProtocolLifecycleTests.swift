import ReplicoCore
import Testing

struct ProtocolLifecycleTests {
    @Test
    func malformedWireAndHeaderShapesKeepTheirProtocolErrors() async throws {
        try await ServerTestConnection.run { connection in
            let malformed = try await connection.request("{")
            #expect(malformed["error"]?["code"] == .integer(-32700))
            #expect(malformed["id"] == .null)
            for source in [
                #"{"jsonrpc":"2.0","id":1,"method":"\uD800"}"#,
                #"{"jsonrpc":"2.0","id":1,"method":"\uDC00"}"#,
                #"{"jsonrpc":"2.0","id":1,"method":"\q"}"#,
                #"{"jsonrpc":"\uD800","id":1,"method":"ping"}"#,
                #"{"jsonrpc":"2.0","id":1,"method":"ping","unknown":"\q"}"#,
                #"{"jsonrpc":"2.0","id":1,"method":"ping","params":{"ignored":"\uD800"}}"#,
                #"{"jsonrpc":"2.0","id":1,"method":"ping","unknown":["\uDC00"]}"#,
                #"{"jsonrpc":"2.0","id":1,"method":"ping","unknown":NaN}"#,
                #"{"jsonrpc":"2.0","id":1,"method":"ping","unknown":[1,]}"#,
                #"{"jsonrpc":"2.0","id":1,"method":"ping",}"#,
                #"{} {}"#,
                #""\q""#,
            ] {
                let response = try await connection.request(source)
                #expect(response["error"]?["code"] == .integer(-32700))
                #expect(response["id"] == .null)
            }
            for source in ["null", "[]", "42", "1e400", #""text""#] {
                let response = try await connection.request(source)
                #expect(response["error"]?["code"] == .integer(-32600))
                #expect(response["id"] == .null)
            }
            let wrongMethod = try await connection.request(#"{"jsonrpc":"1","id":"retained","method":17}"#)
            #expect(wrongMethod["error"]?["code"] == .integer(-32600))
            #expect(wrongMethod["id"] == .string("retained"))
            let nullID = try await connection.request(#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#)
            #expect(nullID["error"]?["code"] == .integer(-32600))
            #expect(nullID["id"] == .null)
            let nullVersion = try await connection.request(#"{"jsonrpc":null,"id":7,"method":"ping"}"#)
            #expect(nullVersion["error"]?["code"] == .integer(-32600))
            #expect(nullVersion["id"] == .integer(7))
            let ignored = try await connection.request(#"{"jsonrpc":"2.0","id":8,"method":"ping","unknown":1e309}"#)
            #expect(ignored["id"] == .integer(8))
            #expect(ignored["result"] == .object([:]))
            let largeUnusedNumber = try await connection.request(
                #"{"jsonrpc":"2.0","id":9,"method":"ping","unknown":1e400}"#)
            #expect(largeUnusedNumber["id"] == .integer(9))
            #expect(largeUnusedNumber["result"] == .object([:]))
        }
    }

    @Test
    func requestAndNotificationKindsRemainSeparate() async throws {
        try await ServerTestConnection.run { connection in
            try await connection.send(message("notifications/initialized"))
            try await connection.send(message("notifications/unknown", parameters: .null))
            try await connection.send(message("initialize", parameters: initializeParameters))
            try await connection.send(message("tools/list"))
            try await connection.send(message("tools/call", parameters: .object(["name": .string("js_reset")])))
            try await connection.send(message("ping"))
            for parameters in [
                JSONValue.null, .object([:]),
                .object([
                    "requestId": .integer(-7), "reason": .bool(false),
                ]),
            ] {
                try await connection.send(message("notifications/cancelled", parameters: parameters))
            }
            let ping = try await connection.request(message("ping", id: .string("after-notifications")))
            #expect(ping["id"] == .string("after-notifications"))
            #expect(ping["result"] == .object([:]))
            let premature = try await connection.request(message("tools/list", id: .integer(2)))
            #expect(premature["error"]?["code"] == .integer(-32600))
            for method in ["notifications/initialized", "notifications/cancelled", "unimplemented/method"] {
                let response = try await connection.request(message(method, id: .string(method), parameters: .null))
                #expect(response["id"] == .string(method))
                #expect(response["error"]?["code"] == .integer(-32601))
            }
            let initialized = try await connection.initialize(id: .integer(3))
            #expect(initialized["result"]?["protocolVersion"] == .string("2025-11-25"))
        }
    }

    @Test
    func initializationStatePrecedesParameterValidation() async throws {
        try await ServerTestConnection.run { connection in
            let premature = try await connection.request(message("tools/call", id: .integer(1), parameters: .null))
            #expect(premature["error"]?["code"] == .integer(-32600))
            let malformed = try await connection.request(message("initialize", id: .integer(2), parameters: .null))
            #expect(malformed["error"]?["code"] == .integer(-32602))
            let initialized = try await connection.request(
                message("initialize", id: .integer(3), parameters: initializeParameters))
            #expect(initialized["result"]?["protocolVersion"] == .string("2025-11-25"))
            let awaitingNotification = try await connection.request(message("tools/list", id: .integer(4)))
            #expect(awaitingNotification["error"]?["code"] == .integer(-32600))
            try await connection.send(message("notifications/initialized"))
            try await connection.send(message("notifications/initialized"))
            let ready = try await connection.request(message("tools/list", id: .integer(5)))
            #expect(ready["result"]?["tools"]?.arrayValue?.count == 3)
            let badCall = try await connection.request(message("tools/call", id: .integer(6), parameters: .null))
            #expect(badCall["error"]?["code"] == .integer(-32602))
            let duplicate = try await connection.request(message("initialize", id: .integer(7), parameters: .null))
            #expect(duplicate["error"]?["code"] == .integer(-32600))
        }
    }

    @Test
    func idsRemainLosslessAndInvalidIdsReturnNull() async throws {
        try await ServerTestConnection.run { connection in
            _ = try await connection.initialize()
            for id in [JSONValue.integer(-42), .string("request-id"), .unsignedInteger(UInt64.max)] {
                let response = try await connection.request(
                    .object([
                        "jsonrpc": .string("2.0"), "id": id, "method": .string("ping"),
                    ]))
                #expect(response["id"] == id)
                #expect(response["result"] == .object([:]))
            }
            let invalid = try await connection.request(
                .object([
                    "jsonrpc": .string("2.0"), "id": .null, "method": .string("ping"),
                ]))
            #expect(invalid["id"] == .null)
            #expect(invalid["error"]?["code"] == .integer(-32600))
        }
    }

    @Test
    func cancellationReachesAnEnteredToolAndTheConnectionRemainsUsable() async throws {
        let tool = SuspendedTool()
        try await ServerTestConnection.run(tools: [tool]) { connection in
            _ = try await connection.initialize()
            try await connection.send(
                .object([
                    "jsonrpc": .string("2.0"), "id": .integer(-7), "method": .string("tools/call"),
                    "params": .object(["name": .string("suspend"), "arguments": .object([:])]),
                ]))
            await tool.waitForEntry()
            try await connection.send(
                .object([
                    "jsonrpc": .string("2.0"), "method": .string("notifications/cancelled"),
                    "params": .object(["requestId": .integer(-7)]),
                ]))
            await tool.waitForCancellation()
            let response = try await connection.request(
                .object([
                    "jsonrpc": .string("2.0"), "id": .string("after-cancellation"), "method": .string("ping"),
                ]))
            #expect(response["id"] == .string("after-cancellation"))
            #expect(response["result"] == .object([:]))
        }
    }

    private var initializeParameters: JSONValue {
        .object([
            "protocolVersion": .string("2025-11-25"),
            "clientInfo": .object(["name": .string("ReplicoTests"), "version": .string("1.0.0")]),
            "capabilities": .object([:]),
        ])
    }

    private func message(_ method: String, id: JSONValue? = nil, parameters: JSONValue? = nil) -> JSONValue {
        var fields: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method)]
        fields["id"] = id
        fields["params"] = parameters
        return .object(fields)
    }
}
