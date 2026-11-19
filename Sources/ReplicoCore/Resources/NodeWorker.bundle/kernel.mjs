import { randomUUID } from "node:crypto"
import path from "node:path"
import { pathToFileURL } from "node:url"
import { NativeEvaluator } from "./native-evaluator.mjs"
import { createRuntimeContext } from "./context.mjs"
import { describeError } from "./errors.mjs"
import { ExecutionScope, executionStorage } from "./execution-scope.mjs"
import { ModuleLoader } from "./module-loader.mjs"

export class Kernel {
    #send
    #services
    #loader
    #evaluator
    #cellIdentifierPrefix
    #helperContext
    #serviceNames
    #initialized = false

    constructor({ cwd, send, services, onFatal }) {
        this.#send = send
        this.#services = services
        // Convert the fixed directory once; ASCII UUID suffixes need no URL escaping.
        this.#cellIdentifierPrefix = pathToFileURL(path.join(cwd, "__replico_")).href
        const name = "Replico-" + randomUUID()
        const parent = { identifier: this.#cellIdentifierPrefix + "cell.mjs" }
        const runtime = createRuntimeContext(onFatal, {
            name,
            importModuleDynamically: (specifier, _, attributes) => this.#loader.dynamicImport(specifier, parent, attributes),
        })
        this.#evaluator = new NativeEvaluator(name, runtime.context)
        this.console = runtime.console
        this.#loader = new ModuleLoader(runtime.context, cwd)
    }

    async evaluate(executionID, parameters) {
        const scope = this.#scope(executionID, parameters)
        if (!this.#initialized) {
            await this.#initialize(executionID, parameters)
        }
        return executionStorage.run(scope, async () => {
            let failure
            try {
                this.#loader.beginEvaluation(parameters.moduleDirectories)
                const identifier = `${this.#cellIdentifierPrefix}${randomUUID()}.mjs`
                failure = await this.#evaluator.evaluate(parameters.code, identifier, executionID)
            } catch (error) {
                failure = describeError(error, "evaluation")
            }
            try {
                await scope.drain()
            } catch (error) {
                failure ??= describeError(error, "helper")
            } finally {
                scope.close()
            }
            return failure === undefined ? { succeeded: true } : { succeeded: false, error: failure }
        })
    }

    #scope(executionID, parameters) {
        const scope = new ExecutionScope({
            ...parameters, executionID, send: this.#send, services: this.#services,
            previousContext: this.#helperContext, serviceNames: parameters.serviceNames ?? this.#serviceNames,
        })
        this.#helperContext = scope.context
        this.#serviceNames = scope.serviceNames
        return scope
    }

    async #initialize(executionID, parameters) {
        const source = parameters.startupSource ?? ""
        if (source.length > 0) {
            const scope = this.#scope(executionID, { metadata: parameters.metadata })
            await executionStorage.run(scope, async () => {
                try {
                    this.#loader.beginEvaluation(parameters.moduleDirectories)
                    await this.#loader.runStartup(source, this.#cellIdentifierPrefix + "startup__.mjs")
                    await scope.drain()
                } finally {
                    scope.close()
                }
            })
        }
        this.#initialized = true
    }
}
