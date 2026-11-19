@testable import ReplicoKit
import Foundation
import MCP
import Testing

struct KitIntegrationTests {
    @Test
    func runtimeGlobalCollisionsFailBeforeUserCodeRuns() async throws {
        let tool = RecordingTool()
        try await KitTestConnection.run(
            application: KitTestApplication(groups: [ToolGroup(name: "console", tools: [tool])])
        ) { connection in
            do {
                _ = try await connection.evaluate("await console.echo({text: 'should not run'})")
                Issue.record("Expected the global namespace collision to reject worker startup.")
            } catch {
                #expect(error.localizedDescription.contains("Tool namespace conflicts"))
            }
            let contexts = await tool.contexts()
            #expect(contexts.isEmpty)
        }
    }

    @Test
    func typedNamespacesRetainMetadataAndReturnAfterReset() async throws {
        let tool = RecordingTool()
        try await KitTestConnection.run(
            application: KitTestApplication(groups: [ToolGroup(name: "text", tools: [tool])])
        ) { connection in
            let first = try await connection.evaluate(
                "await nodeRepl.write('|' + await text.echo({text: 'a', count: 2}))",
                metadata: ["turn": .string("first"), "opaque": .unsignedInteger(UInt64.max)]
            )
            #expect(first.isError == false)
            #expect(first.content == [.text(text: "host:aa|aa", annotations: nil, _meta: nil)])
            try await connection.reset()
            let second = try await connection.evaluate(
                "await text.echo({text: 'b'})", metadata: ["turn": .string("second")])
            #expect(second.content == [.text(text: "host:b", annotations: nil, _meta: nil)])
            let contexts = await tool.contexts()
            #expect(contexts.count == 2)
            #expect(contexts[0].metadata == ["turn": .string("first"), "opaque": .unsignedInteger(UInt64.max)])
            #expect(contexts[1].metadata == ["turn": .string("second")])
            #expect(contexts[0].executionID != contexts[1].executionID)
        }
    }

    @Test
    func frozenDefinitionsDriveActualDispatch() async throws {
        let group = ToolGroup(name: "dynamic", tools: [GeneratedNameTool()])
        let captured = try #require(group.tools.first)
        try await KitTestConnection.run(application: KitTestApplication(groups: [group])) { connection in
            let result = try await connection.evaluate(
                """
                const namespace = dynamic
                try { dynamic.extra = () => 'changed' } catch {}
                await nodeRepl.write([
                    await namespace.\(captured.name)(),
                    Object.isFrozen(dynamic),
                    Object.getPrototypeOf(dynamic) === null,
                    dynamic.extra === undefined
                ].join('|'))
                """)
            #expect(result.isError == false)
            #expect(result.content == [.text(text: "captured|true|true|true", annotations: nil, _meta: nil)])
        }
    }

    @Test
    func typedFailuresAreCatchableAndImagesKeepTheirBytes() async throws {
        let image = try #require(
            Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j8wAAAABJRU5ErkJggg=="
            ))
        try await KitTestConnection.run(
            application: KitTestApplication(groups: [
                ToolGroup(
                    name: "host", tools: [FailingTool(), ImageTool(image: image)]
                )
            ])
        ) { connection in
            let uncaught = try await connection.evaluate("await host.fail()")
            #expect(uncaught.isError == true)
            let caught = try await connection.evaluate(
                """
                try { await host.fail() } catch { await nodeRepl.write('caught') }
                await host.image()
                """)
            #expect(caught.isError == false)
            // Service content arrives on completion before buffered JavaScript text flushes.
            #expect(
                caught.content == [
                    .image(data: image.base64EncodedString(), mimeType: "image/png", annotations: nil, _meta: nil),
                    .text(text: "caught", annotations: nil, _meta: nil),
                ])
        }
    }

    @Test
    func invalidRegistrationsFailBeforeWorkerLaunch() throws {
        let tool = RecordingTool()
        for name in ["await", "", "7echo", "a\u{301}", "\u{212A}", "name\n", "a.b", "a\"b", "a\\b", "a\0b"] {
            #expect(throws: ToolRegistrationError.invalidGroupName(name)) {
                try KitTestApplication(groups: [ToolGroup(name: name, tools: [tool])]).makeServer()
            }
        }
        #expect(throws: ToolRegistrationError.duplicateGroupName("text")) {
            try KitTestApplication(groups: [
                ToolGroup(name: "text", tools: [tool]), ToolGroup(name: "text", tools: []),
            ])
            .makeServer()
        }
        #expect(throws: ToolRegistrationError.duplicateToolName(group: "text", name: "echo")) {
            try KitTestApplication(groups: [ToolGroup(name: "text", tools: [tool, tool])]).makeServer()
        }
    }
}
