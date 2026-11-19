import ReplicoKit
import Foundation
import MCP
import Testing

struct KitConfigurationTests {
    private struct ConfiguredApplication: ReplicoApplication {
        init() {
        }

        var configuration: ApplicationConfiguration {
            var configuration = KitTestApplication().configuration
            configuration.workingDirectory = URL(filePath: "/tmp", directoryHint: .isDirectory)
            configuration.environment["PRIVATE_VALUE"] = "hidden"
            configuration.exposedEnvironment = ["SHARED_VALUE": "visible"]
            configuration.maximumOutputBytes = 64
            return configuration
        }

        let toolGroups: [ToolGroup] = []
    }

    @Test
    func applicationSettingsReachTheHostedWorkerAndBoundItsOutput() async throws {
        try await KitTestConnection.run(application: ConfiguredApplication()) { connection in
            let context = try await connection.evaluate(
                """
                await nodeRepl.write(nodeRepl.cwd + '|' + nodeRepl.env.SHARED_VALUE + '|' + typeof nodeRepl.env.PRIVATE_VALUE)
                """)
            #expect(context.content == [.text(text: "/tmp|visible|undefined", annotations: nil, _meta: nil)])
            await #expect(throws: (any Error).self) {
                try await connection.evaluate("await nodeRepl.write('x'.repeat(65))")
            }
            let recovered = try await connection.evaluate("await nodeRepl.write('ok')")
            #expect(recovered.content == [.text(text: "ok", annotations: nil, _meta: nil)])
        }
    }
}
