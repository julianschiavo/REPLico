import ReplicoCore
import Foundation
import MCP

/// Translates host MCP metadata into an explicit core launch policy.
struct HostIntegration: Sendable {
    static let sandboxStateKey = "codex/sandbox-state"
    static let sandboxStateMetadataKey = "codex/sandbox-state-meta"
    static let sandboxLauncherKey = "codex/sandbox-launcher"
    static let launcherExecutableKey = "codexExecutable"
    static let clientName = "codex-mcp-client"
    static let envKey = "CODEX_CLI_PATH"
    static let experimentalCapabilities = [sandboxStateKey: MCP.Empty()]

    private let configuredLauncher: String?
    private let requiresSandbox: Bool

    init(clientName: String, environment: [String: String]) {
        configuredLauncher = environment[Self.envKey]
        requiresSandbox = clientName == Self.clientName
    }

    /// Unavailable policy is resolved by the core when this evaluation's turn starts.
    func launchPolicy(for metadata: [String: JSONValue]) -> LaunchPolicy {
        let state = metadata[Self.sandboxStateKey]
        let legacyState = metadata[Self.sandboxStateMetadataKey]
        if let state, let legacyState, state != legacyState {
            return .unavailable(.invalidRequest("Conflicting host sandbox policies."))
        }
        guard let policy = state ?? legacyState else {
            return requiresSandbox || configuredLauncher != nil
                ? .unavailable(.invalidConfiguration("Host sandbox policy is required but was not supplied."))
                : .direct
        }
        guard policy.objectValue != nil else {
            return .unavailable(.invalidRequest("Host sandbox policy must be an object."))
        }
        let metadataLauncher: String?
        if let launcher = metadata[Self.sandboxLauncherKey] {
            guard let path = launcher[Self.launcherExecutableKey]?.stringValue else {
                return .unavailable(.invalidRequest("Host sandbox launcher metadata is malformed."))
            }
            metadataLauncher = path
        } else {
            metadataLauncher = nil
        }
        guard let path = metadataLauncher ?? configuredLauncher, path.hasPrefix("/") else {
            return .unavailable(.invalidConfiguration("A verified absolute host sandbox launcher is required."))
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let serialized = String(decoding: try encoder.encode(policy), as: UTF8.self)
            let launcher = try SandboxLauncher(
                executable: URL(filePath: path), arguments: ["sandbox", "--sandbox-state-json", serialized, "--"]
            )
            return .sandboxed(launcher)
        } catch is EncodingError {
            return .unavailable(.invalidRequest("Host sandbox policy cannot be represented as JSON."))
        } catch {
            return .unavailable(.invalidConfiguration("A verified absolute host sandbox launcher is required."))
        }
    }
}
