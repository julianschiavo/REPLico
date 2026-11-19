import ReplicoCore
import Foundation
import Testing

struct RetiredWorkerIntegrationTests {
    @Test
    func retiredWorkerPipeCannotFailItsReplacement() async throws {
        let service = BarrierService()
        try await RuntimeFixture(services: [service])
            .run { fixture in
                let node = fixture.repository.appending(path: ".runtime/ReplicoRuntime.artifactbundle/bin/node").path
                let childSource = """
                    process.stdout.on('error', () => {
                    })
                    process.stdin.on('end', () => {
                        process.stdout.write(JSON.stringify({ fatal: {
                            executionID: null,
                            error: { message: 'retired worker event' }
                        } }) + '\\n')
                    })
                    process.stdin.resume()
                    process.send('ready')
                    """
                let nodeLiteral = String(decoding: try JSONEncoder().encode(node), as: UTF8.self)
                let childLiteral = String(decoding: try JSONEncoder().encode(childSource), as: UTF8.self)
                let evaluation = Task {
                    try await fixture.session.evaluate(
                        EvaluationRequest(
                            code: """
                                const childProcess = await import('node:child_process')
                                const child = childProcess.spawn(\(nodeLiteral), ['-e', \(childLiteral)], {
                                    detached: true,
                                    stdio: ['pipe', 'inherit', 'inherit', 'ipc']
                                })
                                await new Promise((resolve, reject) => {
                                    child.once('message', resolve)
                                    child.once('error', reject)
                                })
                                child.disconnect()
                                await nodeRepl.rpc('barrier', {})
                                """))
                }
                await service.waitForEntry()
                await fixture.session.reset()
                await #expect(throws: REPLError.reset) {
                    try await evaluation.value
                }
                let recovered = try await fixture.session.evaluate(
                    EvaluationRequest(code: "await nodeRepl.write('fresh')"))
                #expect(!recovered.didFail)
                #expect(recovered.content == [.text("fresh")])
            }
    }
}
