import { createContext } from "node:vm"
import { activeScope, executionStorage } from "./execution-scope.mjs"

export function createRuntimeContext(onFatal, { name = "Replico", importModuleDynamically } = {}) {
    const nodeRepl = Object.freeze({
        get cwd() {
            return activeScope().context.cwd
        },
        get homeDir() {
            return activeScope().context.homeDir
        },
        get tmpDir() {
            return activeScope().context.tmpDir
        },
        get env() {
            return activeScope().context.env
        },
        get requestMeta() {
            return activeScope().metadata
        },
        write(value, itemID) {
            return activeScope().write(value, itemID)
        },
        emitImage(input) {
            return activeScope().emitImage(input)
        },
        get rpc() {
            const scope = activeScope()
            if (scope.serviceNames.size === 0) {
                return undefined
            }
            return callService
        },
    })
    const console = createConsole()
    const context = createContext({
        console,
        Buffer,
        TextEncoder,
        TextDecoder,
        URL,
        URLSearchParams,
        AbortController,
        AbortSignal,
        setTimeout: scopedScheduler(setTimeout, onFatal),
        clearTimeout,
        setInterval: scopedScheduler(setInterval, onFatal),
        clearInterval,
        setImmediate: scopedScheduler(setImmediate, onFatal),
        clearImmediate,
        queueMicrotask: scopedScheduler(queueMicrotask, onFatal),
        structuredClone,
        atob,
        btoa,
        fetch,
        Headers,
        Request,
        Response,
        FormData,
        Blob,
        File,
        ReadableStream,
        WritableStream,
        TransformStream,
        crypto: globalThis.crypto,
        performance,
    }, {
        name,
        importModuleDynamically,
        codeGeneration: { strings: false },
    })
    Object.defineProperty(context, "nodeRepl", { value: nodeRepl })
    return { context, console }
}

function scopedScheduler(schedule, onFatal) {
    return function (callback, ...arguments_) {
        if (typeof callback !== "function") {
            throw new TypeError("A scheduled callback must be a function")
        }
        const scope = activeScope()
        return schedule((...values) => {
            executionStorage.run(scope, () => {
                try {
                    callback(...values)
                } catch (error) {
                    if (onFatal === undefined) {
                        throw error
                    }
                    onFatal(error, scope.executionID)
                }
            })
        }, ...arguments_)
    }
}

function callService(service, request) {
    return activeScope().rpc(service, request)
}

function createConsole() {
    const methods = {}
    for (const name of ["log", "info", "debug", "warn", "error"]) {
        methods[name] = (...values) => {
            activeScope().log(values)
        }
    }
    return Object.freeze({
        ...methods,
        dir(value) {
            activeScope().write(value)
        },
        assert(condition, ...values) {
            if (!condition) {
                activeScope().log(["Assertion failed:", ...values])
            }
        },
        trace(...values) {
            activeScope().log([new Error(values.join(" ")).stack])
        },
    })
}
