import MCP

struct InitializeResponse: Encodable, Sendable {
    struct Capabilities: Encodable, Sendable {
        let tools = MCP.Server.Capabilities.Tools(listChanged: false)
        let experimental = HostIntegration.experimentalCapabilities
    }

    let protocolVersion: String
    let capabilities = Capabilities()
    let serverInfo: ReplicoServer.Info
    let instructions =
        "Use js for JavaScript with top-level await in one persistent Node session. "
        + "Bindings persist and can be redeclared. Use nodeRepl.write(value) for output. "
        + "Use js_reset to discard the kernel and js_add_node_module_dir for package imports."
}
