import ReplicoCore
import Foundation
import Testing

struct SandboxAuthorityIntegrationTests {
    @Test
    func changedLaunchPoliciesReplaceTheKernelAndCannotDowngradeAfterReset() async throws {
        try await RuntimeFixture()
            .run { fixture in
                let launcher = try makeLauncher(in: fixture)
                let first = LaunchPolicy.sandboxed(try SandboxLauncher(executable: launcher, arguments: ["revision-1"]))
                let second = LaunchPolicy.sandboxed(
                    try SandboxLauncher(executable: launcher, arguments: ["revision-2"]))
                _ = try await fixture.session.evaluate(EvaluationRequest(code: "let directValue = 1"))
                let replaced = try await fixture.session.evaluate(
                    EvaluationRequest(
                        code: "nodeRepl.write(typeof directValue); let sandboxValue = 2", launchPolicy: first
                    ))
                #expect(replaced.content == [.text("undefined")])
                let retained = try await fixture.session.evaluate(
                    EvaluationRequest(code: "nodeRepl.write(sandboxValue)", launchPolicy: first))
                #expect(retained.content == [.text("2")])
                let changed = try await fixture.session.evaluate(
                    EvaluationRequest(code: "nodeRepl.write(typeof sandboxValue)", launchPolicy: second))
                #expect(changed.content == [.text("undefined")])
                await fixture.session.reset()
                await #expect(throws: REPLError.self) {
                    try await fixture.session.evaluate(EvaluationRequest(code: "nodeRepl.write('must not run')"))
                }
                let recovered = try await fixture.session.evaluate(
                    EvaluationRequest(code: "nodeRepl.write('sandboxed again')", launchPolicy: second))
                #expect(recovered.content == [.text("sandboxed again")])
            }
    }

    @Test
    func unavailableAuthorityLatchesTheRequirementAndClearsThePriorKernel() async throws {
        try await RuntimeFixture()
            .run { fixture in
                _ = try await fixture.session.evaluate(EvaluationRequest(code: "let prior = 42"))
                let unavailable = REPLError.invalidConfiguration("Required launch authority is unavailable.")
                await #expect(throws: unavailable) {
                    try await fixture.session.evaluate(
                        EvaluationRequest(
                            code: "throw Error('must not execute')", launchPolicy: .unavailable(unavailable)))
                }
                await fixture.session.reset()
                await #expect(throws: REPLError.self) {
                    try await fixture.session.evaluate(EvaluationRequest(code: "nodeRepl.write('must not run')"))
                }
                let launcher = try makeLauncher(in: fixture)
                let policy = LaunchPolicy.sandboxed(
                    try SandboxLauncher(executable: launcher, arguments: ["revision-1"]))
                let recovered = try await fixture.session.evaluate(
                    EvaluationRequest(code: "nodeRepl.write(typeof prior)", launchPolicy: policy))
                #expect(recovered.content == [.text("undefined")])
            }
    }

    @Test
    func unavailableQueuedAuthorityDoesNotPreemptTheActiveEvaluation() async throws {
        let service = BarrierService()
        try await RuntimeFixture(services: [service])
            .run { fixture in
                let active = Task {
                    try await fixture.session.evaluate(
                        EvaluationRequest(code: "await nodeRepl.rpc('barrier', {}); nodeRepl.write('current')"))
                }
                await service.waitForEntry()
                let unavailable = REPLError.invalidConfiguration("Required launch authority is unavailable.")
                let queued = await enqueue(
                    EvaluationRequest(code: "throw Error('must not execute')", launchPolicy: .unavailable(unavailable)),
                    on: fixture.session
                )
                await service.release()
                let completed = try await active.value
                #expect(completed.content == [.text("current")])
                await #expect(throws: unavailable) {
                    try await queued.value
                }
            }
    }

    private func enqueue(_ request: EvaluationRequest, on session: isolated REPLSession) -> Task<
        EvaluationResult, any Error
    > {
        Task.immediate {
            try await session.evaluate(request)
        }
    }

    private func makeLauncher(in fixture: RuntimeFixture) throws -> URL {
        let launcher = fixture.directory.appending(path: "launcher")
        // This forwarding fixture tests authority identity and argv plumbing, not OS sandbox enforcement.
        try fixture.write(
            """
            #!/bin/sh
            [ "$1" = "revision-1" ] || [ "$1" = "revision-2" ] || exit 71
            shift
            exec "$@"
            """, to: "launcher")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        return launcher
    }
}
