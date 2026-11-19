import { Session } from "node:inspector/promises"
import { Script, createContext } from "node:vm"
import { describeError } from "./errors.mjs"

export class NativeEvaluator {
    #session = new Session()
    #ready
    #workspace
    #name
    #contexts = new Map()
    #controller
    #script

    constructor(name, workspace) {
        this.#name = name
        this.#workspace = workspace
    }

    #connect() {
        this.#session.connect()
        this.#session.on("Runtime.executionContextCreated", ({ params: { context } }) => {
            const { name, uniqueId } = context
            if (name === this.#name || name === this.#name + "-script") {
                this.#contexts.set(name, this.#contexts.has(name) ? null : uniqueId)
            }
        })
        return this.#session.post("Runtime.enable")
    }

    /**
     * With Session.post("Runtime.evaluate", { expression: source, … }), the inspector
     * converts the entire source to its binary protocol. For large ordinary scripts,
     * new Script(source).runInContext(workspace) accepts that same source directly.
     * Invoking it inside the inspector request preserves the lifetime of helper output.
     * Only the private context can invoke the runner.
     */
    #prepareScript(source, identifier) {
        let script
        try {
            script = new Script(source, { filename: identifier })
        } catch (error) {
            if (error instanceof SyntaxError) {
                return false
            }
            throw error
        }
        this.#controller ??= createContext({
            run: () => {
                this.#script.runInContext(this.#workspace, { displayErrors: false })
            },
            describeError: new Script(`(${describeError})`).runInContext(this.#workspace),
        }, { name: this.#name + "-script", codeGeneration: { strings: false } })
        this.#script = script
        return true
    }

    async evaluate(code, identifier, executionID) {
        await (this.#ready ??= this.#connect())
        // The empty binding pattern cannot complete a dangling statement or introduce a name.
        const source = `"use strict";\n${code}\nconst {} = 0\nvoid 0\n//# sourceURL=${identifier}`
        // A regular Script can use existing REPL bindings. Reserve every possible
        // declaration, escaped spelling, import and await for V8's REPL grammar.
        const scripted = code.length >= 16_384 && !/await|class|const|function|import|let|using|var|\\/.test(code)
            && this.#prepareScript(source, identifier)
        const uniqueContextId = this.#contexts.get(scripted ? this.#name + "-script" : this.#name)
        if (!uniqueContextId) {
            this.#script = undefined
            throw new Error("The JavaScript workspace context is unavailable")
        }
        let reply
        try {
            reply = await this.#session.post("Runtime.evaluate", {
                expression: scripted ? '"use strict"; run(); void 0' : source,
                uniqueContextId,
                replMode: true,
                awaitPromise: true,
                allowUnsafeEvalBlockedByCSP: false,
                objectGroup: executionID,
            })
        } finally {
            this.#script = undefined
        }
        const { result, exceptionDetails } = reply
        if (!exceptionDetails) {
            return
        }
        try {
            const kind = result.className === "SyntaxError" && exceptionDetails.stackTrace?.callFrames[0]?.url === "node:inspector"
                ? "syntax" : "evaluation"
            const { objectId, unserializableValue, value } = result
            const detail = await this.#session.post("Runtime.callFunctionOn", {
                uniqueContextId,
                functionDeclaration: scripted ? "function (error, kind) { return describeError(error, kind) }" : String(describeError),
                arguments: [{ objectId, unserializableValue, value }, { value: kind }],
                returnByValue: true,
                objectGroup: executionID,
            })
            const error = detail.result.value
            return typeof error?.message === "string" && typeof error.kind === "string" ? error
                : { message: "The thrown value could not be inspected", kind }
        } finally {
            await this.#session.post("Runtime.releaseObjectGroup", { objectGroup: executionID })
        }
    }
}
