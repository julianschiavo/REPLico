import { promiseHooks } from "node:v8"
import { describeError, WorkerError } from "./errors.mjs"
import { executionStorage } from "./execution-scope.mjs"
import { Kernel } from "./kernel.mjs"
import { ServiceBridge } from "./services.mjs"
import { Transport } from "./transport.mjs"

const originalOutput = process.stdout.write.bind(process.stdout)
const originalError = process.stderr.write.bind(process.stderr)
const transport = new Transport(originalOutput)
const services = new ServiceBridge(send)
const kernel = new Kernel({ cwd: process.cwd(), send, services, onFatal: fatal })
const sources = []
let activeOperation
let fatalPending = false

function send({ event, ...payload }) {
    if (event === "output" && payload.content?.type === "image" && Object.isFrozen(payload.content)
        && typeof payload.executionID === "string" && Object.keys(payload).every(key => key === "content" || key === "executionID")) {
        return transport.sendImage(payload.executionID, payload.content)
    }
    return transport.send({ [event]: payload })
}

function captureOutput(stream) {
    return function (chunk, encoding, callback) {
        const completed = typeof encoding === "function" ? encoding : callback
        const scope = executionStorage.getStore()
        if (scope === undefined) {
            originalError(`[${stream}] ${String(chunk)}`)
            completed?.()
            return true
        }
        try {
            const text = typeof chunk === "string" ? chunk : Buffer.from(chunk).toString(typeof encoding === "string" ? encoding : "utf8")
            scope.write(text)
            completed?.()
        } catch (error) {
            completed?.(error)
        }
        return true
    }
}

process.stdout.write = captureOutput("stdout")
process.stderr.write = captureOutput("stderr")
globalThis.console = kernel.console
process.removeAllListeners("warning")
process.on("warning", warning => {
    originalError(`${warning.name}: ${warning.message}\n`)
})

async function fatal(error, originatingExecutionID) {
    if (fatalPending) {
        return
    }
    fatalPending = true
    const executionID = originatingExecutionID ?? executionStorage.getStore()?.executionID
    try {
        await send({ event: "fatal", ...(executionID === undefined ? {} : { executionID }), error: describeError(error, "asynchronous") })
    } finally {
        process.exit(1)
    }
}

process.on("uncaughtException", error => {
    fatal(error)
})
// A promise can be rejected by a later cell. Attribute the failure to its creator.
const promiseOwners = new WeakMap()
promiseHooks.onInit(promise => {
    const scope = executionStorage.getStore()
    if (scope !== undefined) {
        promiseOwners.set(promise, scope.executionID)
    }
})
process.on("unhandledRejection", (error, promise) => {
    fatal(error, promiseOwners.get(promise))
})

function receive(command) {
    const entries = command !== null && typeof command === "object" && !Array.isArray(command) ? Object.entries(command) : []
    if (entries.length !== 1) {
        throw new WorkerError("Commands require one evaluate or serviceReply case", "protocol")
    }
    const [method, parameters] = entries[0]
    if (method === "serviceReply") {
        try {
            services.reply(parameters)
        } catch (error) {
            if (error.kind !== "stale_execution") {
                throw error
            }
        }
    } else if (method === "evaluate" && !activeOperation?.evaluating) {
        const operation = { evaluating: true }
        activeOperation = operation
        if (parameters.startup) {
            transport.textDeltas = parameters.startup.textDeltas === true
            transport.binaryImages = parameters.startup.binaryImages === true
        }
        const evaluation = parameters.startup ? { ...parameters, ...parameters.startup } : parameters
        if (typeof evaluation.code === "string") {
            if (evaluation.code.length <= 1024 * 1024) {
                if (sources.length === 8) {
                    sources.shift()
                }
                sources.push(evaluation.code)
            }
        } else if (Number.isInteger(evaluation.code) && evaluation.code >= 0 && evaluation.code < sources.length) {
            evaluation.code = sources[evaluation.code]
        } else {
            throw new WorkerError("Expected JavaScript source or a retained source slot", "protocol")
        }
        operation.completed = kernel.evaluate(parameters.executionID, evaluation)
            .then(result => {
                // Kernel work ends before completion is published. EOF still waits for the write.
                operation.evaluating = false
                return send({ event: "completed", executionID: parameters.executionID, ...result })
            })
        operation.completed.catch(fatal)
    } else {
        throw new WorkerError("Expected one evaluation at a time or a service reply", "protocol")
    }
}

await send({ event: "ready", version: 1, nodeVersion: process.versions.node })
try {
    await transport.read(process.stdin, receive)
    await activeOperation?.completed
    if (!fatalPending) {
        process.exit(0)
    }
} catch (error) {
    await fatal(error)
}
