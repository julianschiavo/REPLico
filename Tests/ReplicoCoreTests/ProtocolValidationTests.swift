import Foundation
import Testing
@testable import ReplicoCore

struct ProtocolValidationTests {
    private struct UnavailableNode: EmbeddedNodeRuntime {
        static let executableURL = URL(filePath: "/missing/node")
        static let failure = REPLError.invalidConfiguration("The fixture runtime could not be installed.")

        static func installedExecutable() throws -> URL {
            throw failure
        }
    }

    @Test
    func embeddedNodeIsRequiredOnlyWhenAnEvaluationCanLaunchAWorker() async throws {
        var configuration = REPLConfiguration(
            node: .embedded(UnavailableNode.self), workingDirectory: URL(filePath: "/"),
            environment: [:], exposedEnvironment: [:], maximumOutputBytes: 1_024
        )
        #expect(configuration.nodeExecutable == UnavailableNode.executableURL)
        let policyError = REPLError.invalidConfiguration("No sandbox launcher.")
        #expect(throws: policyError) {
            try LaunchPolicy.unavailable(policyError).makeWorkerLaunch(configuration: configuration)
        }
        let session = try REPLSession(configuration: configuration)
        try await session.addNodeModuleDirectory(at: URL(filePath: "/tmp/node_modules"))
        await #expect(throws: UnavailableNode.failure) {
            try await session.evaluate(EvaluationRequest(code: "42"))
        }
        await session.shutDown()

        let external = URL(filePath: "/usr/bin/false")
        configuration.nodeExecutable = external
        #expect(try configuration.node.installedURL() == external)
    }

    @Test
    func unavailableAuthorityPreservesItsFailure() throws {
        let configuration = REPLConfiguration(
            nodeExecutable: URL(filePath: "/node"),
            environment: [:]
        )
        for failure in [
            REPLError.invalidConfiguration("Missing launch authority."), .invalidRequest("Malformed launch authority."),
        ] {
            #expect(throws: failure) {
                try LaunchPolicy.unavailable(failure).makeWorkerLaunch(configuration: configuration)
            }
        }
    }
}
