import ReplicoCore
import Testing

struct ModuleIntegrationTests {
    @Test
    func localFilesReloadAndPackagesStayCached() async throws {
        try await RuntimeFixture()
            .run { fixture in
                try fixture.write("export const value = 1", to: "value.mjs")
                try fixture.write("export { value } from './value.mjs'", to: "entry.mjs")
                try fixture.write(
                    #"{"name":"example","type":"module","main":"index.mjs"}"#,
                    to: "node_modules/example/package.json"
                )
                try fixture.write("export const value = 1", to: "node_modules/example/index.mjs")
                let setup = try await fixture.session.evaluate(
                    EvaluationRequest(
                        code: "const load = () => Promise.all([import('./entry.mjs'), import('example')])"))
                #expect(!setup.didFail)
                let code = "nodeRepl.write((await load()).map(module => module.value))"
                let first = try await fixture.session.evaluate(EvaluationRequest(code: code))
                #expect(!first.didFail)
                #expect(first.text == "[ 1, 1 ]")
                try fixture.write("export const value = 2", to: "value.mjs")
                try fixture.write("export const value = 2", to: "node_modules/example/index.mjs")
                let second = try await fixture.session.evaluate(EvaluationRequest(code: code))
                #expect(!second.didFail)
                #expect(second.text == "[ 2, 1 ]")
            }
    }

    @Test
    func addedModuleDirectoriesSurviveResetWhileBindingsDoNot() async throws {
        try await RuntimeFixture()
            .run { fixture in
                try fixture.write(
                    #"{"name":"external","type":"module","main":"index.mjs"}"#,
                    to: "packages/node_modules/external/package.json"
                )
                try fixture.write("export const value = 23", to: "packages/node_modules/external/index.mjs")
                try await fixture.session.addNodeModuleDirectory(
                    at: fixture.directory.appending(path: "packages/node_modules")
                )
                let first = try await fixture.session.evaluate(
                    EvaluationRequest(
                        code: """
                            const imported = await import("external");
                            await nodeRepl.write(imported.value);
                            """))
                #expect(!first.didFail)
                #expect(first.text == "23")
                await fixture.session.reset()
                let second = try await fixture.session.evaluate(
                    EvaluationRequest(
                        code: """
                            await nodeRepl.write([typeof imported, (await import("external")).value]);
                            """))
                #expect(!second.didFail)
                #expect(second.text == "[ 'undefined', 23 ]")
            }
    }
}
