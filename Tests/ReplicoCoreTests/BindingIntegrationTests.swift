import ReplicoCore
import Testing

struct BindingIntegrationTests {
    @Test
    func repeatedCellsUseTheCurrentStateAndRequestMetadata() async throws {
        try await RuntimeFixture()
            .run { fixture in
                let source = """
                    globalThis.count = (globalThis.count ?? 0) + 1
                    if (nodeRepl.requestMeta.fail) throw Error('interrupted')
                    nodeRepl.write([globalThis.count, nodeRepl.requestMeta.tag].join(':'))
                    """
                func run(_ tag: String, fail: Bool = false) async throws -> EvaluationResult {
                    try await fixture.session.evaluate(
                        EvaluationRequest(code: source, metadata: ["tag": .string(tag), "fail": .bool(fail)]))
                }
                #expect(try await run("first").text == "1:first")
                #expect(try await run("second", fail: true).didFail)
                _ = try await fixture.session.evaluate(EvaluationRequest(code: "globalThis.count += 10"))
                #expect(try await run("third").text == "13:third")
                for index in 0..<10 {
                    _ = try await fixture.session.evaluate(EvaluationRequest(code: "void \(index)"))
                }
                #expect(try await run("later").text == "14:later")
                await fixture.session.reset()
                #expect(try await run("fresh").text == "1:fresh")
            }
    }

    @Test
    func canonicallyEquivalentCellsPreserveTheirJavaScriptCodeUnits() async throws {
        try await RuntimeFixture()
            .run { fixture in
                for marks in ["\u{0307}\u{0323}", "\u{0323}\u{0307}", "\u{0307}\u{0323}"] {
                    let source = "nodeRepl.write('\(marks)'.charCodeAt(0))"
                    let result = try await fixture.session.evaluate(EvaluationRequest(code: source))
                    #expect(result.text == String(try #require(marks.utf16.first)))
                }
            }
    }

    @Test
    func closuresFollowLiveBindingsAcrossCells() async throws {
        try await RuntimeFixture()
            .run { fixture in
                let first = try await fixture.session.evaluate(
                    EvaluationRequest(
                        code: """
                            let value = 1
                            const read = () => value
                            const box = {}
                            const original = box
                            """))
                #expect(!first.didFail)
                let second = try await fixture.session.evaluate(
                    EvaluationRequest(
                        code: """
                            let value = 2
                            box.value = read()
                            nodeRepl.write([read(), original === box, original.value])
                            """))
                #expect(!second.didFail)
                #expect(second.text == "[ 2, true, 2 ]")
            }
    }

    @Test
    func constantsCanBeRedeclaredButRejectAssignment() async throws {
        try await RuntimeFixture()
            .run { fixture in
                _ = try await fixture.session.evaluate(EvaluationRequest(code: "const value = 1"))
                let redeclared = try await fixture.session.evaluate(EvaluationRequest(code: "const value = 2"))
                #expect(!redeclared.didFail)
                #expect(redeclared.content.isEmpty)
                let assigned = try await fixture.session.evaluate(EvaluationRequest(code: "value += 1"))
                #expect(assigned.didFail)
                let read = try await fixture.session.evaluate(EvaluationRequest(code: "nodeRepl.write(value)"))
                #expect(read.text == "2")
            }
    }

    @Test
    func interruptedDestructuringKeepsInitializedNames() async throws {
        try await RuntimeFixture()
            .run { fixture in
                let failed = try await fixture.session.evaluate(
                    EvaluationRequest(code: "const { first, second = missing() } = { first: 4 }"))
                #expect(failed.didFail)
                let first = try await fixture.session.evaluate(EvaluationRequest(code: "nodeRepl.write(first)"))
                #expect(first.text == "4")
                let second = try await fixture.session.evaluate(
                    EvaluationRequest(code: "nodeRepl.write(typeof second)"))
                #expect(second.didFail)
            }
    }

    @Test
    func hoistedVariablesSurviveInterruptedInitialization() async throws {
        try await RuntimeFixture()
            .run { fixture in
                let failed = try await fixture.session.evaluate(
                    EvaluationRequest(
                        code: """
                            before = 9
                            var { completed, interrupted = missing() } = { completed: 4 }
                            var before, unreached
                            """))
                #expect(failed.didFail)
                let read = try await fixture.session.evaluate(
                    EvaluationRequest(code: "nodeRepl.write([before, completed, interrupted, unreached])"))
                #expect(read.text == "[ 9, 4, undefined, undefined ]")
            }
    }

    @Test
    func syntaxAndStaticImportErrorsPreserveThePreviousNamespace() async throws {
        try await RuntimeFixture()
            .run { fixture in
                _ = try await fixture.session.evaluate(EvaluationRequest(code: "const retained = 12"))
                let syntax = try await fixture.session.evaluate(EvaluationRequest(code: "let ="))
                #expect(syntax.didFail)
                let importResult = try await fixture.session.evaluate(
                    EvaluationRequest(code: "import fs from 'node:fs'"))
                #expect(importResult.didFail)
                let result = try await fixture.session.evaluate(
                    EvaluationRequest(code: "await nodeRepl.write(retained)"))
                #expect(!result.didFail)
                #expect(result.text == "12")
            }
    }

    @Test
    func scopesAndUnicodeOffsetsPreserveEvaluationOrder() async throws {
        try await RuntimeFixture()
            .run { fixture in
                let result = try await fixture.session.evaluate(
                    EvaluationRequest(
                        code: """
                            const emoji = "😀";
                            var value = 1;
                            class Holder {
                                static {
                                    var value = 99;
                                }
                            }
                            switch (0) {
                                case 0:
                                    let value = 2;
                                    value++;
                                    await nodeRepl.write([emoji, value]);
                            }
                            for (var { last } of [{last: 4}, {last: 5}]) {
                            }
                            await nodeRepl.write([value, last]);
                            """))
                #expect(!result.didFail)
                #expect(result.text == "[ '😀', 3 ][ 1, 5 ]")
            }
    }

    @Test
    func recursiveFunctionsRetainTheirOriginalSourceText() async throws {
        try await RuntimeFixture()
            .run { fixture in
                let result = try await fixture.session.evaluate(
                    EvaluationRequest(
                        code: """
                            function count(value) {
                                return value === 0 ? 0 : count(value - 1) + 1;
                            }
                            await nodeRepl.write(count.toString());
                            """))
                #expect(!result.didFail)
                #expect(
                    result.text == """
                        function count(value) {
                            return value === 0 ? 0 : count(value - 1) + 1;
                        }
                        """)
            }
    }
}
