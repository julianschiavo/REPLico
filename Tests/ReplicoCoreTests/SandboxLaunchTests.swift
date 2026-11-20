@testable import ReplicoCore
import Foundation
import Testing

struct SandboxLaunchTests {
    @Test
    func launcherPreservesItsPrefixAndAppendsTheNodeInvocation() throws {
        let launcher = try SandboxLauncher(
            executable: URL(filePath: "/usr/bin/false"),
            arguments: ["isolate", "opaque application policy", "--"]
        )
        let configuration = REPLConfiguration(nodeExecutable: URL(filePath: "/engine/node"), environment: [:])
        let command = try LaunchPolicy.sandboxed(launcher).makeWorkerLaunch(configuration: configuration)
        #expect(command.executable == launcher.executable)
        #expect(Array(command.arguments.prefix(4)) == launcher.arguments + ["/engine/node"])
        #expect(
            Array(command.arguments.dropFirst(4).prefix(2)) == [
                "--experimental-vm-modules", "--experimental-import-meta-resolve",
            ])
        let script = try #require(command.arguments.last)
        #expect(URL(filePath: script).lastPathComponent == "worker.mjs")
        #expect(FileManager.default.isReadableFile(atPath: script))
    }

    @Test
    func directPolicyLaunchesNodeWithoutALauncherPrefix() throws {
        let configuration = REPLConfiguration(nodeExecutable: URL(filePath: "/engine/node"), environment: [:])
        let command = try LaunchPolicy.direct.makeWorkerLaunch(configuration: configuration)
        #expect(command.executable == configuration.nodeExecutable)
        #expect(command.arguments.first == "--experimental-vm-modules")
    }

    @Test
    func launchersRejectNonFileURLsMissingExecutablesAndNULArguments() throws {
        let remote = try #require(URL(string: "https://example.com/launcher"))
        #expect(throws: REPLError.self) {
            try SandboxLauncher(executable: remote, arguments: [])
        }
        #expect(throws: REPLError.self) {
            try SandboxLauncher(executable: URL(filePath: "/missing-replico-launcher"), arguments: [])
        }
        #expect(throws: REPLError.self) {
            try SandboxLauncher(executable: URL(filePath: "/"), arguments: [])
        }
        #expect(throws: REPLError.self) {
            try SandboxLauncher(executable: URL(filePath: "/usr/bin/false"), arguments: ["invalid\0argument"])
        }
    }
}
