import ReplicoCore
import Foundation
import Testing

struct APIBoundaryTests {
    @Test(arguments: [Duration.zero, .nanoseconds(-1)])
    func nonpositiveTimeoutsAreRejected(_ timeout: Duration) async throws {
        try await RuntimeFixture()
            .run { fixture in
                await #expect(throws: REPLError.self) {
                    try await fixture.session.evaluate(EvaluationRequest(code: "1", timeout: timeout))
                }
            }
    }

    @Test
    func fractionalMillisecondTimeoutReachesTheEvaluationClockExactly() async throws {
        let clock = DeadlineClock()
        let service = BarrierService()
        try await RuntimeFixture(services: [service], clock: clock)
            .run { fixture in
                let evaluation = Task {
                    try await fixture.session.evaluate(
                        EvaluationRequest(
                            code: "await nodeRepl.rpc('barrier', {})", timeout: .microseconds(125)
                        ))
                }
                await clock.waitForRegistration()
                await service.waitForEntry()
                #expect(await clock.scheduledInstant?.offset == .microseconds(125))
                await clock.fire()
                await #expect(throws: REPLError.timedOut) {
                    try await evaluation.value
                }
            }
    }

    @Test
    func moduleDirectoriesRequireAbsoluteFileURLsAndCanBeMissing() async throws {
        try await RuntimeFixture()
            .run { fixture in
                for url in [
                    try #require(URL(string: "https://example.com/node_modules")),
                    try #require(URL(string: "file:node_modules")),
                    fixture.directory.appending(path: "packages"),
                ] {
                    await #expect(throws: REPLError.self) {
                        try await fixture.session.addNodeModuleDirectory(at: url)
                    }
                }
                try await fixture.session.addNodeModuleDirectory(
                    at: fixture.directory.appending(path: "missing/../node_modules")
                )
                await fixture.session.reset()
                let result = try await fixture.session.evaluate(EvaluationRequest(code: "nodeRepl.write(2 + 3)"))
                #expect(result.content == [.text("5")])
            }
    }

    @Test
    func shutdownRejectsAdmissionBeforeServiceCleanupFinishes() async throws {
        let service = BarrierService(holdsCleanup: true)
        try await RuntimeFixture(services: [service])
            .run { fixture in
                let active = Task {
                    try await fixture.session.evaluate(EvaluationRequest(code: "await nodeRepl.rpc('barrier', {})"))
                }
                await service.waitForEntry()
                let closing = Task {
                    await fixture.session.shutDown()
                }
                await service.waitForCancellation()
                await #expect(throws: REPLError.closed) {
                    try await fixture.session.evaluate(EvaluationRequest(code: "1"))
                }
                await #expect(throws: REPLError.closed) {
                    try await fixture.session.addNodeModuleDirectory(
                        at: fixture.directory.appending(path: "node_modules"))
                }
                await service.release()
                await closing.value
                await #expect(throws: REPLError.closed) {
                    try await active.value
                }
                await #expect(throws: REPLError.closed) {
                    try await fixture.session.addNodeModuleDirectory(
                        at: fixture.directory.appending(path: "node_modules"))
                }
            }
    }

    @Test
    func shutdownStrengthensAnOngoingResetAndRejectsQueuedRequests() async throws {
        let service = BarrierService(holdsCleanup: true)
        try await RuntimeFixture(services: [service])
            .run { fixture in
                let active = Task {
                    try await fixture.session.evaluate(EvaluationRequest(code: "await nodeRepl.rpc('barrier', {})"))
                }
                await service.waitForEntry()
                let resetting = Task {
                    await fixture.session.reset()
                }
                await service.waitForCancellation()
                let queued = await enqueue(
                    EvaluationRequest(code: "nodeRepl.write('must not run')"), on: fixture.session)
                let closing = await shutDown(fixture.session)
                await #expect(throws: REPLError.closed) {
                    try await queued.value
                }
                await service.release()
                await resetting.value
                await closing.value
                await #expect(throws: REPLError.reset) {
                    try await active.value
                }
                await #expect(throws: REPLError.closed) {
                    try await fixture.session.evaluate(EvaluationRequest(code: "1"))
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

    private func shutDown(_ session: isolated REPLSession) -> Task<Void, Never> {
        Task.immediate {
            await session.shutDown()
        }
    }

}
