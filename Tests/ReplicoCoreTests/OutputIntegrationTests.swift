import ReplicoCore
import Foundation
import Testing

struct OutputIntegrationTests {
    @Test
    func plainAndEscapedWorkerTextPreserveTheirUTF8Bytes() async throws {
        try await RuntimeFixture()
            .run { fixture in
                for text in ["\u{FEFF}é🙂漢", "quote\" slash\\ newline\n nul\0"] {
                    let literal = String(decoding: try JSONEncoder().encode(text), as: UTF8.self)
                    let result = try await fixture.session.evaluate(
                        EvaluationRequest(code: "nodeRepl.write(\(literal))"))
                    #expect(!result.didFail)
                    #expect(Data(result.text.utf8) == Data(text.utf8))
                }
            }
    }

    @Test
    func changingLargeOutputIsReevaluatedEvenWhenACellThrows() async throws {
        try await RuntimeFixture()
            .run { fixture in
                let side = String(repeating: "é🧭", count: 8_192)
                _ = try await fixture.session.evaluate(
                    EvaluationRequest(code: "globalThis.side = 'é🧭'.repeat(8192); globalThis.revision = 0"))
                for revision in 1...4 {
                    let result = try await fixture.session.evaluate(
                        EvaluationRequest(
                            code: """
                                nodeRepl.write('\\uFEFF' + side + (++revision) + side)
                                if (revision === 3) throw Error('planned')
                                """))
                    let output = REPLContent.text("\u{FEFF}" + side + String(revision) + side)
                    #expect(result.didFail == (revision == 3))
                    #expect(result.content == (revision == 3 ? [output, .text("planned")] : [output]))
                }
            }
    }

    @Test
    func repeatedOutputIsChargedAtItsFullSize() async throws {
        try await RuntimeFixture(maximumOutputBytes: 65_536)
            .run { fixture in
                for _ in 0..<2 {
                    _ = try await fixture.session.evaluate(EvaluationRequest(code: "nodeRepl.write('x'.repeat(65536))"))
                }
                await #expect(
                    throws: REPLError.protocolViolation("Execution output exceeds the configured byte limit.")
                ) {
                    try await fixture.session.evaluate(
                        EvaluationRequest(code: "nodeRepl.write('extra','named'); nodeRepl.write('x'.repeat(65536))"))
                }
                let fresh = try await fixture.session.evaluate(EvaluationRequest(code: "nodeRepl.write('fresh')"))
                #expect(fresh.content == [.text("fresh")])
            }
    }

    @Test
    func textAndImagesHaveSeparateTypedContent() async throws {
        try await RuntimeFixture()
            .run { fixture in
                let encoded =
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j8wAAAABJRU5ErkJggg=="
                let result = try await fixture.session.evaluate(
                    EvaluationRequest(
                        code: """
                            await nodeRepl.write("before");
                            await nodeRepl.emitImage(Buffer.from("\(encoded)", "base64"));
                            await nodeRepl.write("after");
                            """))
                #expect(!result.didFail)
                #expect(
                    result.content == [
                        .text("beforeafter"),
                        .image(data: try #require(Data(base64Encoded: encoded)), mimeType: "image/png"),
                    ])
            }
    }

    @Test
    func namedTextItemsAccumulateIndependently() async throws {
        try await RuntimeFixture()
            .run { fixture in
                let result = try await fixture.session.evaluate(
                    EvaluationRequest(
                        code: """
                            await nodeRepl.write("a", "first");
                            await nodeRepl.write("b", "second");
                            await nodeRepl.write("c", "first");
                            """))
                #expect(!result.didFail)
                #expect(result.content == [.text("ac"), .text("b")])
            }
    }

    @Test
    func registeredServicesReceiveMetadataAndReturnStructuredValues() async throws {
        try await RuntimeFixture(services: [EchoService()])
            .run { fixture in
                let result = try await fixture.session.evaluate(
                    EvaluationRequest(
                        code: """
                            const reply = await nodeRepl.rpc("echo", {value: 7});
                            await nodeRepl.write([reply.payload.value, reply.metadata.turn]);
                            """,
                        metadata: ["turn": .string("test")]
                    ))
                #expect(!result.didFail)
                #expect(result.text == "service:[ 7, 'test' ]")
            }
    }

    @Test
    func unobservedHelperFailuresFailTheCellAndCaughtFailuresDoNot() async throws {
        try await RuntimeFixture()
            .run { fixture in
                let failed = try await fixture.session.evaluate(
                    EvaluationRequest(
                        code: """
                            nodeRepl.emitImage(new Uint8Array([1, 2]));
                            """))
                #expect(failed.didFail)
                let caught = try await fixture.session.evaluate(
                    EvaluationRequest(
                        code: """
                            try {
                                await nodeRepl.emitImage(new Uint8Array([1, 2]));
                            } catch {
                                await nodeRepl.write("caught");
                            }
                            """))
                #expect(!caught.didFail)
                #expect(caught.text == "caught")
            }
    }

    @Test
    func outputLimitsStopTheWorkerAndAllowRecovery() async throws {
        try await RuntimeFixture(maximumOutputBytes: 16)
            .run { fixture in
                do {
                    _ = try await fixture.session.evaluate(
                        EvaluationRequest(
                            code: """
                                await nodeRepl.write("x".repeat(17));
                                """))
                    Issue.record("Expected the output limit to stop evaluation.")
                } catch let error as REPLError {
                    guard case .protocolViolation = error else {
                        throw error
                    }
                }
                let recovered = try await fixture.session.evaluate(
                    EvaluationRequest(code: "await nodeRepl.write('ready')"))
                #expect(!recovered.didFail)
                #expect(recovered.text == "ready")
            }
    }

    @Test
    func serviceAndWorkerOutputShareOneBudget() async throws {
        try await RuntimeFixture(services: [EchoService()], maximumOutputBytes: 8)
            .run { fixture in
                await #expect(throws: REPLError.self) {
                    try await fixture.session.evaluate(
                        EvaluationRequest(
                            code: """
                                await nodeRepl.write('abc');
                                await nodeRepl.rpc('echo', {});
                                """))
                }
            }
    }

    @Test
    func finalJavaScriptDiagnosticsRemainVisibleAfterTheOutputBudgetIsFilled() async throws {
        try await RuntimeFixture(maximumOutputBytes: 4)
            .run { fixture in
                let result = try await fixture.session.evaluate(
                    EvaluationRequest(
                        code: """
                            await nodeRepl.write('full');
                            throw Error('diagnostic');
                            """))
                #expect(result.didFail)
                #expect(result.content.first == .text("full"))
                #expect(result.text.contains("diagnostic"))
            }
    }

}
