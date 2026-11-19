import ReplicoCore
import Foundation
import Testing

struct LifecycleIntegrationTests {
    @Test
    func cancellationStopsAnEnteredServiceAndClearsKernelState() async throws {
        let service = BarrierService()
        try await RuntimeFixture(services: [service])
            .run { fixture in
                let evaluation = Task {
                    try await fixture.session.evaluate(
                        EvaluationRequest(
                            code: """
                                const lost = 42;
                                await nodeRepl.rpc("barrier", {});
                                """))
                }
                await service.waitForEntry()
                evaluation.cancel()
                await #expect(throws: CancellationError.self) {
                    try await evaluation.value
                }
                await service.waitForCancellation()
                let recovered = try await fixture.session.evaluate(
                    EvaluationRequest(code: "await nodeRepl.write(typeof lost)"))
                #expect(!recovered.didFail)
                #expect(recovered.text == "undefined")
            }
    }

    @Test
    func resetStopsAnEnteredEvaluationAndStartsAFreshKernel() async throws {
        let service = BarrierService()
        try await RuntimeFixture(services: [service])
            .run { fixture in
                let evaluation = Task {
                    try await fixture.session.evaluate(
                        EvaluationRequest(
                            code: """
                                const lost = 42;
                                await nodeRepl.rpc("barrier", {});
                                """))
                }
                await service.waitForEntry()
                await fixture.session.reset()
                await #expect(throws: REPLError.reset) {
                    try await evaluation.value
                }
                await service.waitForCancellation()
                let recovered = try await fixture.session.evaluate(
                    EvaluationRequest(code: "await nodeRepl.write(typeof lost)"))
                #expect(recovered.text == "undefined")
            }
    }

    @Test
    func aManuallyFiredDeadlineStopsEvaluationWithoutWallClockWaiting() async throws {
        let service = BarrierService()
        let clock = DeadlineClock()
        try await RuntimeFixture(services: [service], clock: clock)
            .run { fixture in
                let evaluation = Task {
                    try await fixture.session.evaluate(
                        EvaluationRequest(
                            code: """
                                const lost = 42;
                                await nodeRepl.rpc("barrier", {});
                                """))
                }
                await clock.waitForRegistration()
                await service.waitForEntry()
                await clock.fire()
                await #expect(throws: REPLError.timedOut) {
                    try await evaluation.value
                }
                await service.waitForCancellation()
                let recovered = try await fixture.session.evaluate(
                    EvaluationRequest(code: "await nodeRepl.write(typeof lost)"))
                #expect(recovered.text == "undefined")
            }
    }

    @Test
    func cancellingAQueuedRequestDoesNotInterruptTheCurrentRequest() async throws {
        let service = BarrierService()
        try await RuntimeFixture(services: [service])
            .run { fixture in
                let current = Task {
                    try await fixture.session.evaluate(
                        EvaluationRequest(
                            code: """
                                await nodeRepl.rpc("barrier", {});
                                await nodeRepl.write("current");
                                """))
                }
                await service.waitForEntry()
                let queued = Task {
                    try await fixture.session.evaluate(EvaluationRequest(code: "await nodeRepl.write('queued')"))
                }
                queued.cancel()
                await #expect(throws: CancellationError.self) {
                    try await queued.value
                }
                await service.release()
                let completed = try await current.value
                #expect(!completed.didFail)
                #expect(completed.text == "current")
            }
    }

    @Test
    func aCrashedWorkerIsReplacedWhileItsChildStillHoldsStandardOutput() async throws {
        try await RuntimeFixture()
            .run { fixture in
                let nodePath = fixture.repository.appending(path: ".runtime/ReplicoRuntime.artifactbundle/bin/node")
                    .path
                let literal = String(decoding: try JSONEncoder().encode(nodePath), as: UTF8.self)
                do {
                    _ = try await fixture.session.evaluate(
                        EvaluationRequest(
                            code: """
                                const lost = 42;
                                const child = await import("node:child_process");
                                child.execFileSync(\(literal), ["-e", `
                                    process.stdin.resume()
                                    process.kill(process.ppid, 'SIGKILL')
                                `], { stdio: ['inherit', 'inherit', 'ignore'] });
                                """))
                    Issue.record("Expected the worker process to exit.")
                } catch let error as REPLError {
                    guard case .workerExited = error else {
                        throw error
                    }
                }
                let recovered = try await fixture.session.evaluate(
                    EvaluationRequest(code: "await nodeRepl.write(typeof lost)"))
                #expect(!recovered.didFail)
                #expect(recovered.text == "undefined")
            }
    }

    @Test
    func shutdownClosesTheSession() async throws {
        try await RuntimeFixture()
            .run { fixture in
                await fixture.session.shutDown()
                await #expect(throws: REPLError.closed) {
                    try await fixture.session.evaluate(EvaluationRequest(code: "1"))
                }
            }
    }
}
