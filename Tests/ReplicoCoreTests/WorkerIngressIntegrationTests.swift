import ReplicoCore
import Testing

struct WorkerIngressIntegrationTests {
    @Test(arguments: ["[10]", "[255, 10]"])
    func invalidFramesKeepTheirProtocolFailureAndAllowRecovery(_ bytes: String) async throws {
        try await RuntimeFixture()
            .run { fixture in
                await #expect(
                    throws: REPLError.protocolViolation("Worker returned an empty or invalid UTF-8 frame.")
                ) {
                    try await fixture.session.evaluate(
                        EvaluationRequest(
                            code: """
                                const fs = await import('node:fs')
                                fs.writeSync(1, Buffer.from(\(bytes)))
                                """))
                }
                let recovered = try await fixture.session.evaluate(EvaluationRequest(code: "nodeRepl.write('fresh')"))
                #expect(recovered.content == [.text("fresh")])
            }
    }

    @Test
    func unterminatedFramesKeepTheirProtocolFailureAndAllowRecovery() async throws {
        try await RuntimeFixture()
            .run { fixture in
                await #expect(
                    throws: REPLError.protocolViolation("Worker exited with an unterminated protocol frame.")
                ) {
                    try await fixture.session.evaluate(
                        EvaluationRequest(
                            code: """
                                const fs = await import('node:fs')
                                fs.writeSync(1, '{')
                                fs.closeSync(1)
                                """))
                }
                let recovered = try await fixture.session.evaluate(EvaluationRequest(code: "nodeRepl.write('fresh')"))
                #expect(recovered.content == [.text("fresh")])
            }
    }

    @Test
    func staleExecutionFramesDoNotAffectTheActiveEvaluation() async throws {
        try await RuntimeFixture()
            .run { fixture in
                let result = try await fixture.session.evaluate(
                    EvaluationRequest(
                        code: """
                            const fs = await import('node:fs');
                            const executionID = '00000000-0000-0000-0000-000000000000';
                            for (const frame of [
                                { output: { executionID, content: { type: 'text', text: 'ignored' } } },
                                { output: { executionID, content: { type: 'text', update: {
                                    change: { key: 'bad', base: 'retired', prefix: -1, suffix: 0, insert: '' }
                                } } } },
                                { service: { executionID, requestID: 'stale', service: 'missing', request: {} } },
                                { completed: { executionID, succeeded: true } }
                            ]) {
                                fs.writeSync(1, JSON.stringify(frame) + '\\n');
                            }
                            await nodeRepl.write('current');
                            """))
                #expect(!result.didFail)
                #expect(result.content == [.text("current")])
            }
    }

    @Test
    func completionWithPendingHostServicesCancelsAndAwaitsTheirCleanup() async throws {
        let cleanup = BarrierService(holdsCleanup: true)
        try await RuntimeFixture(services: [cleanup, ExecutionIDService(cleanup: cleanup)])
            .run { fixture in
                let evaluation = Task {
                    try await fixture.session.evaluate(
                        EvaluationRequest(
                            code: """
                                const fs = await import('node:fs');
                                nodeRepl.rpc('barrier', {});
                                const executionID = await nodeRepl.rpc('executionID', {});
                                fs.writeSync(1, JSON.stringify({ completed: { executionID, succeeded: true } }) + '\\n');
                                """))
                }
                await cleanup.waitForCancellation()
                await cleanup.release()
                do {
                    _ = try await evaluation.value
                    Issue.record("Expected early completion to violate the worker protocol.")
                } catch let error as REPLError {
                    guard case .protocolViolation = error else {
                        throw error
                    }
                }
                let recovered = try await fixture.session.evaluate(EvaluationRequest(code: "nodeRepl.write('fresh')"))
                #expect(recovered.content == [.text("fresh")])
            }
    }

    private struct ExecutionIDService: REPLService {
        let name = "executionID"
        let cleanup: BarrierService

        func call(_ request: ServiceRequest) async throws -> ServiceResponse {
            await cleanup.waitForEntry()
            return ServiceResponse(value: .string(request.executionID))
        }
    }
}
