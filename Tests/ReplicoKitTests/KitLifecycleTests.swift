import ReplicoKit
import MCP
import Testing

struct KitLifecycleTests {
    @Test
    func facadeCancellationReachesTheEnteredToolAndAllowsRecovery() async throws {
        let tool = SuspendedTool()
        try await KitTestConnection.run(
            application: KitTestApplication(groups: [ToolGroup(name: "host", tools: [tool])])
        ) { connection in
            try await connection.sendEvaluation("await host.wait()", id: "pending")
            await tool.waitForEntry()
            try await connection.cancel("pending")
            await tool.waitForCancellation()
            let recovered = try await connection.evaluate("await nodeRepl.write(typeof host.wait)")
            #expect(recovered.isError == false)
            #expect(recovered.content == [.text(text: "function", annotations: nil, _meta: nil)])
        }
    }

    @Test
    func namespacesAreIsolatedBetweenSessions() async throws {
        let alpha = KitTestApplication(groups: [ToolGroup(name: "alpha", tools: [RecordingTool()])])
        let beta = KitTestApplication(groups: [ToolGroup(name: "beta", tools: [RecordingTool()])])
        try await KitTestConnection.run(application: alpha) { first in
            try await KitTestConnection.run(application: beta) { second in
                let query = "await nodeRepl.write(typeof alpha + '|' + typeof beta)"
                let firstResult = try await first.evaluate(query)
                let secondResult = try await second.evaluate(query)
                #expect(firstResult.content == [.text(text: "object|undefined", annotations: nil, _meta: nil)])
                #expect(secondResult.content == [.text(text: "undefined|object", annotations: nil, _meta: nil)])
            }
        }
    }

    @Test
    func malformedNoArgumentsCallsNeverReachTheBackend() async throws {
        let tool = CountingTool()
        try await KitTestConnection.run(
            application: KitTestApplication(groups: [ToolGroup(name: "host", tools: [tool])])
        ) { connection in
            let result = try await connection.evaluate(
                """
                const outcomes = []
                for (const arguments_ of [null, 1, true, 'text', [], {extra: true}]) {
                    try {
                        await host.empty(arguments_)
                        outcomes.push('unexpected')
                    } catch {
                        outcomes.push('rejected')
                    }
                }
                outcomes.push(String(await host.empty()))
                await nodeRepl.write(outcomes.join('|'))
                """)
            #expect(result.isError == false)
            #expect(
                result.content == [
                    .text(text: "rejected|rejected|rejected|rejected|rejected|rejected|1", annotations: nil, _meta: nil)
                ])
            let count = await tool.invocationCount()
            #expect(count == 1)
        }
    }
}
