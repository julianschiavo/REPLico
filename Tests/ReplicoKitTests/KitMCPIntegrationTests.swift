@testable import ReplicoKit
import MCP
import Testing

struct KitMCPIntegrationTests {
    private struct DynamicApplication: ReplicoApplication {
        init() {
        }

        var configuration: ApplicationConfiguration {
            var configuration = KitTestApplication().configuration
            configuration.serverInfo = .init(name: "inventory", version: "2.3.4", title: "Store Inventory")
            return configuration
        }

        var toolGroups: [ToolGroup] {
            [ToolGroup(name: "dynamic", tools: [GeneratedNameTool()])]
        }
    }

    @Test
    func advertisedMethodsUseTheSameSnapshotAsTheHostedSession() async throws {
        let server = try DynamicApplication().makeServer()
        let transports = await InMemoryTransport.createConnectedPair()
        try await transports.server.connect()
        let serving = Task {
            try await server.run(over: transports.server)
        }
        let client = Client(name: "ReplicoKitTests", version: "1")
        do {
            let initialized = try await client.connect(transport: transports.client)
            #expect(initialized.serverInfo == .init(name: "inventory", version: "2.3.4", title: "Store Inventory"))
            let listing = try await client.send(ListTools.request(.init())).value
            #expect(Set(listing.tools.map(\.name)) == ["js", "js_reset", "js_add_node_module_dir"])
            let javaScript = try #require(listing.tools.first { $0.name == "js" })
            let line = try #require(
                javaScript.description?.split(separator: "\n")
                    .first {
                        $0.hasPrefix("await dynamic.")
                    })
            let method = try #require(line.split(separator: "(").first).dropFirst("await ".count)
            let code = "await nodeRepl.write(await \(method)())"
            let first = try await client.send(CallTool.request(.init(name: "js", arguments: ["code": .string(code)])))
                .value
            #expect(first.content == [.text(text: "captured", annotations: nil, _meta: nil)])
            #expect(first.isError == false)
            _ = try await client.send(CallTool.request(.init(name: "js_reset"))).value
            let reset = try await client.send(CallTool.request(.init(name: "js", arguments: ["code": .string(code)])))
                .value
            #expect(reset.content == first.content)
            await client.disconnect()
            try await serving.value
        } catch {
            await client.disconnect()
            try await serving.value
            throw error
        }
    }
}
