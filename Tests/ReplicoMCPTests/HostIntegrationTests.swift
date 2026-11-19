import ReplicoCore
@testable import ReplicoMCP
import Foundation
import Testing

struct HostIntegrationTests {
    @Test
    func opaquePolicyUsesThePublicLauncherArguments() {
        let integration = HostIntegration(clientName: "ReplicoTests", environment: [:])
        let policy = integration.launchPolicy(for: [
            HostIntegration.sandboxStateKey: .object([
                "permissionProfile": .object(["futureField": .array([.string("kept"), .integer(17)])]),
                "unsigned": .unsignedInteger(UInt64.max),
                "unknownTopLevel": .bool(true),
            ]),
            HostIntegration.sandboxLauncherKey: .object([
                HostIntegration.launcherExecutableKey: .string("/usr/bin/false")
            ]),
        ])
        guard case .sandboxed(let launcher) = policy else {
            Issue.record("Expected a validated sandbox launcher.")
            return
        }
        #expect(launcher.executable == URL(filePath: "/usr/bin/false"))
        #expect(
            launcher.arguments == [
                "sandbox", "--sandbox-state-json",
                #"{"permissionProfile":{"futureField":["kept",17]},"unknownTopLevel":true,"unsigned":18446744073709551615}"#,
                "--",
            ])
    }

    @Test
    func missingPolicyIsRequiredByTheClientOrConfiguredLauncher() {
        #expect(HostIntegration(clientName: "ReplicoTests", environment: [:]).launchPolicy(for: [:]) == .direct)
        for integration in [
            HostIntegration(clientName: HostIntegration.clientName, environment: [:]),
            HostIntegration(clientName: "ReplicoTests", environment: [HostIntegration.envKey: "/usr/bin/false"]),
        ] {
            guard case .unavailable(.invalidConfiguration(_)) = integration.launchPolicy(for: [:]) else {
                Issue.record("Expected missing policy to remain an unavailable configuration.")
                continue
            }
        }
    }

    @Test
    func malformedMetadataDoesNotFallBackToAnEnvironmentLauncher() {
        let integration = HostIntegration(
            clientName: "ReplicoTests", environment: [HostIntegration.envKey: "/usr/bin/false"]
        )
        for metadata in [
            [HostIntegration.sandboxStateKey: JSONValue.string("invalid")],
            [
                HostIntegration.sandboxStateKey: .object([:]),
                HostIntegration.sandboxStateMetadataKey: .object(["different": .bool(true)]),
            ],
            [
                HostIntegration.sandboxStateKey: .object([:]),
                HostIntegration.sandboxLauncherKey: .object([HostIntegration.launcherExecutableKey: .integer(1)]),
            ],
        ] {
            guard case .unavailable(.invalidRequest(_)) = integration.launchPolicy(for: metadata) else {
                Issue.record("Expected malformed host metadata to remain an unavailable request.")
                continue
            }
        }
        for path in ["relative/launcher", "/replico/nonexistent/launcher"] {
            let policy = integration.launchPolicy(for: [
                HostIntegration.sandboxStateKey: .object([:]),
                HostIntegration.sandboxLauncherKey: .object([HostIntegration.launcherExecutableKey: .string(path)]),
            ])
            guard case .unavailable(.invalidConfiguration(_)) = policy else {
                Issue.record("Expected an invalid explicit launcher to block environment fallback.")
                continue
            }
        }
    }
}
