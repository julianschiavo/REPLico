import ReplicoCore
import ReplicoMCP

/// Hosts typed Swift tools through a persistent JavaScript MCP connection.
///
/// Declare an @main conforming type for the default entry point, or call serve()
/// from an existing application's asynchronous entry point.
public protocol ReplicoApplication: Sendable {
    /// Creates the application used by the default executable entry point.
    init()

    /// The identity and process settings captured for the hosted connection.
    var configuration: ApplicationConfiguration {
        get
    }

    /// The namespaces and typed tools captured for the hosted connection.
    var toolGroups: [ToolGroup] {
        get
    }
}

extension ReplicoApplication {
    /// Default process settings using Node included by the ReplicoKit product.
    public var configuration: ApplicationConfiguration {
        ApplicationConfiguration()
    }

    /// Serves one standard IO MCP connection and awaits all owned cleanup before returning.
    ///
    /// Configuration and tool groups are captured once. EOF or cancellation stops the
    /// worker and cancels admitted calls. Tools must cooperate with cancellation.
    public func serve() async throws {
        try await makeServer().runUsingStandardIO()
    }

    /// Runs the default application entry point and owns connection cleanup.
    public static func main() async throws {
        try await Self().serve()
    }

    func makeServer() throws -> ReplicoServer {
        let configuration = self.configuration
        let groups = toolGroups
        var names: Set<String> = []
        let prepared = try groups.map { group in
            let api = try group.prepare()
            guard names.insert(group.name).inserted else {
                throw ToolRegistrationError.duplicateGroupName(group.name)
            }
            return api
        }
        let session = try REPLSession(
            configuration: configuration.makeEngineConfiguration(),
            services: groups.flatMap(\.registrations),
            startupSource: prepared.map(\.startupSource).joined(separator: "\n")
        )
        let instructions =
            "JavaScript host tools (call these methods from js):\n"
            + prepared.map(\.documentation).joined(separator: "\n\n")
        return try ReplicoServer(
            session: session,
            serverInfo: configuration.serverInfo,
            tools: [
                JavaScriptTool(session: session, additionalInstructions: instructions),
                ResetTool(session: session),
                AddNodeModuleDirectoryTool(session: session),
            ],
            environment: configuration.environment
        )
    }

}
