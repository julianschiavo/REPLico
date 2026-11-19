import { AsyncLocalStorage } from "node:async_hooks"
import { randomUUID } from "node:crypto"
import { format, inspect, isDeepStrictEqual } from "node:util"
import { imageBytes, imageContent } from "./images.mjs"
import { WorkerError } from "./errors.mjs"

export const executionStorage = new AsyncLocalStorage()

export class ExecutionScope {
    #send
    #open = true
    #operations = []
    #services
    #serviceNames
    #context
    #namedText = new Map()
    #text = []
    #separator = ""
    #images = []
    #bufferedBytes = 0

    constructor({ executionID, send, services, serviceNames, metadata, context, previousContext }) {
        if (typeof executionID !== "string" || executionID.length === 0) {
            throw new WorkerError("An execution ID is required", "protocol")
        }
        this.executionID = executionID
        this.#send = send
        this.#services = services
        this.#serviceNames = serviceNames instanceof Set ? serviceNames : new Set(serviceNames)
        this.metadata = immutableJSON(metadata ?? null)
        this.#context = previousContext !== undefined && (context === undefined || isDeepStrictEqual(previousContext, context))
            ? previousContext : immutableJSON(context)
    }

    get context() {
        return this.#context
    }

    get serviceNames() {
        return this.#serviceNames
    }

    assertOpen() {
        if (!this.#open) {
            throw new WorkerError("This execution has completed", "stale_execution")
        }
    }

    track(operation) {
        this.assertOpen()
        const entry = { observed: false, outcome: { type: "pending" }, settled: undefined }
        const promise = Promise.resolve().then(() => {
            this.assertOpen()
            return operation()
        })
        entry.settled = promise.then(
            () => {
                entry.outcome = { type: "succeeded" }
            },
            error => {
                entry.outcome = { type: "failed", error }
            },
        )
        this.#operations.push(entry)
        return Object.freeze({
            then(fulfilled, rejected) {
                entry.observed = true
                return promise.then(fulfilled, rejected)
            },
            catch(rejected) {
                entry.observed = true
                return promise.catch(rejected)
            },
            finally(completed) {
                entry.observed = true
                return promise.finally(completed)
            },
            [Symbol.toStringTag]: "Promise",
        })
    }

    write(value, itemID) {
        this.assertOpen()
        if (itemID !== undefined && (typeof itemID !== "string" || itemID.length === 0)) {
            throw new TypeError("nodeRepl.write expected a nonempty string content item ID")
        }
        const text = typeof value === "string" ? value : inspect(value, { depth: 6, maxArrayLength: 100, breakLength: 100 })
        if (itemID === undefined) {
            this.appendText(text, false)
        } else {
            this.reserveBufferedBytes(Buffer.byteLength(text))
            this.#namedText.set(itemID, (this.#namedText.get(itemID) ?? "") + text)
        }
    }

    log(values) {
        this.assertOpen()
        this.appendText(format(...values), true)
    }

    appendText(text, newline) {
        const bytes = text.length === 1 && text.charCodeAt(0) < 128 ? 1 : Buffer.byteLength(text)
        this.reserveBufferedBytes(bytes + this.#separator.length)
        this.#text.push(this.#separator + text)
        this.#separator = newline ? "\n" : ""
    }

    reserveBufferedBytes(count) {
        if (this.#bufferedBytes + count > 64 * 1024 * 1024) {
            throw new WorkerError("Buffered output exceeds the 64 MiB worker limit", "output_limit")
        }
        this.#bufferedBytes += count
    }

    emitImage(input) {
        return this.track(async () => {
            const content = await imageContent(input)
            this.reserveBufferedBytes(imageBytes(content)?.length ?? Buffer.byteLength(content.data, "base64"))
            this.#images.push(content)
        })
    }

    rpc(service, request) {
        return this.track(async () => {
            if (typeof service !== "string" || !this.#serviceNames.has(service)) {
                throw new WorkerError(`Service is unavailable: ${String(service)}`, "service_unavailable")
            }
            const requestID = randomUUID()
            return this.#services.invoke({
                executionID: this.executionID,
                requestID,
                service,
                request,
            })
        })
    }

    async emit(content) {
        this.assertOpen()
        await this.#send({ event: "output", executionID: this.executionID, content })
    }

    async drain() {
        let completedCount = 0
        while (completedCount < this.#operations.length) {
            const operations = this.#operations.slice(completedCount)
            completedCount = this.#operations.length
            await Promise.all(operations.map(entry => entry.settled))
        }
        for (const [itemID, text] of this.#namedText) {
            await this.emit({ type: "text", text, itemID })
        }
        this.#namedText.clear()
        if (this.#text.length > 0) {
            const text = this.#text.join("")
            this.#text = []
            this.#separator = ""
            await this.emit({ type: "text", text })
        }
        for (const image of this.#images.splice(0)) {
            await this.emit(image)
        }
        this.#bufferedBytes = 0
        for (const entry of this.#operations) {
            if (!entry.observed && entry.outcome.type === "failed") {
                throw entry.outcome.error
            }
        }
    }

    close() {
        this.#open = false
    }
}

export function activeScope() {
    const scope = executionStorage.getStore()
    if (scope === undefined) {
        throw new WorkerError("This helper requires an active execution", "stale_execution")
    }
    scope.assertOpen()
    return scope
}

function immutableJSON(value) {
    return freeze(structuredClone(value))
}

function freeze(value) {
    if (value !== null && typeof value === "object") {
        for (const child of Object.values(value)) {
            freeze(child)
        }
        Object.freeze(value)
    }
    return value
}
