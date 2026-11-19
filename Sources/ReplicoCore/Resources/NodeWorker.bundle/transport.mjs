import { randomUUID } from "node:crypto"
import { addAbortSignal, finished } from "node:stream"
import { imageBytes } from "./images.mjs"
import { WorkerError } from "./errors.mjs"

const imageMIMETypes = ["image/jpeg", "image/png", "image/webp", "image/gif"]
const uuid = /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/

export const maximumFrameBytes = 64 * 1024 * 1024

/**
 * Bounded JSON lines over a native Node stream.
 *
 * Async iteration creates per-chunk iterator promises. This input path uses native
 * data callbacks and stream.finished, preserving EOF, destruction, and error handling.
 * Both paths dispatch the same LF decoder without awaiting its command callback.
 *
 * Standard Readable iteration, with an existing frame decoder:
 *     for await (const chunk of input) {
 *         decodeFrames(chunk, receive)
 *     }
 *
 * This transport, including framing and native stream completion:
 *     await transport.read(input, receive)
 */
export class Transport {
    #write
    #snapshot
    textDeltas = false
    binaryImages = false

    constructor(write) {
        this.#write = write
    }

    // Keep full bytes only after two large outputs share an interior sample.
    // The bounded Buffer owns its storage independently of a V8 substring.
    // A change refers to the last full output the host accepted in this kernel.
    #textValue(value) {
        const { executionID, content } = value.output
        const text = content.text
        if (!this.textDeltas || content.type !== "text" || content.itemID !== undefined || text.length > 2 * 1024 * 1024
            || typeof executionID !== "string" || executionID.length > 128) {
            return value
        }
        const prior = this.#snapshot
        const block = 4096
        const head = Buffer.from(text.slice(block, block + 64), "utf16le")
        const tail = Buffer.from(text.slice(-block - 64, -block), "utf16le")
        const next = this.#snapshot = { head, tail }
        if (!prior || (!head.equals(prior.head) && !tail.equals(prior.tail)) || !text.isWellFormed()) {
            return value
        }
        const bytes = Buffer.from(text)
        if (bytes.length < 65536 || bytes.length > 2 * 1024 * 1024) {
            return value
        }
        next.bytes = bytes
        const base = prior.bytes
        let prefix = 0
        let suffix = 0
        if (base && bytes.equals(base)) {
            prefix = bytes.length
        } else if (base) {
            const length = Math.min(base.length, bytes.length)
            while (prefix + block <= length && bytes.compare(base, prefix, prefix + block, prefix, prefix + block) === 0) {
                prefix += block
            }
            while (suffix + prefix + block <= length
                && bytes.compare(base, base.length - suffix - block, base.length - suffix,
                    bytes.length - suffix - block, bytes.length - suffix) === 0) {
                suffix += block
            }
        }
        if (base && prefix + suffix < bytes.length / 2) {
            return value
        }
        const key = next.key = randomUUID()
        if (!prior.key) {
            return { output: { executionID, content: { type: "text", update: { seed: { key } }, text } } }
        }
        return { output: { executionID, content: {
            type: "text", update: { change: { key, base: prior.key, prefix, suffix,
                insert: bytes.toString("base64", prefix, bytes.length - suffix) } },
        } } }
    }

    sendImage(executionID, content) {
        return this.#send({ output: { executionID, content } }, content)
    }

    send(value) {
        return this.#send(value)
    }

    async #send(value, image) {
        const bytes = image === undefined ? undefined : imageBytes(image)
        if (bytes && typeof value.output.executionID === "string") {
            const id = value.output.executionID
            if (this.binaryImages && id.length === 36 && uuid.test(id)) {
                // NUL and a four-byte body length precede UUID, MIME tag, image bytes and final LF.
                const frame = Buffer.alloc(43 + bytes.length)
                frame.writeUInt32BE(37 + bytes.length, 1)
                frame.write(id, 5, 36, "ascii")
                frame[41] = imageMIMETypes.indexOf(image.mimeType)
                bytes.copy(frame, 42)
                frame[frame.length - 1] = 10
                return this.#writeFrame(frame)
            }
            return this.#writeFrame('{"output":{"executionID":' + JSON.stringify(value.output.executionID)
                + ',"content":{"type":"image","data":"' + image.data + '","mimeType":' + JSON.stringify(image.mimeType) + '}}}')
        }
        if (value.output?.content?.text?.length >= 21846) {
            value = this.#textValue(value)
        }
        const encoded = JSON.stringify(value, value.service === undefined ? undefined : function (key, item) {
            if (this === value.service && key === "request"
                && (item === undefined || typeof item === "function" || typeof item === "symbol")) {
                throw new TypeError("A service request must serialize to a JSON value")
            }
            return item
        })
        return this.#writeFrame(encoded)
    }

    #writeFrame(encoded) {
        if (typeof encoded === "string") {
            if (Buffer.byteLength(encoded, "utf8") > maximumFrameBytes) {
                throw new WorkerError("Worker output exceeds the frame limit", "protocol")
            }
            encoded += "\n"
        }
        return new Promise((resolve, reject) => {
            this.#write(encoded, error => {
                if (error !== undefined && error !== null) {
                    reject(error)
                } else {
                    resolve()
                }
            })
        })
    }

    async read(input, receive) {
        return new Promise((resolve, reject) => {
            let fragments = []
            let accumulated = 0
            const pending = []
            let failure
            let cleanup

            function consume(chunk) {
                const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk)
                let start = 0
                for (;;) {
                    const end = bytes.indexOf(10, start)
                    const fragment = bytes.subarray(start, end === -1 ? bytes.length : end)
                    accumulated += fragment.length
                    if (accumulated > maximumFrameBytes) {
                        throw new WorkerError("Worker input exceeds the frame limit", "protocol")
                    }
                    fragments.push(fragment)
                    if (end === -1) {
                        break
                    }
                    const line = (fragments.length === 1 ? fragment : Buffer.concat(fragments, accumulated)).toString("utf8")
                    fragments = []
                    accumulated = 0
                    if (line.trim().length !== 0) {
                        receive(JSON.parse(line))
                    }
                    start = end + 1
                    if (start === bytes.length) {
                        break
                    }
                }
            }

            function data(chunk) {
                // Keep the current chunk queued while receive may synchronously push more input.
                pending.push(chunk)
                if (pending.length !== 1) {
                    return
                }
                try {
                    while (pending.length !== 0) {
                        consume(pending[0])
                        pending.shift()
                    }
                } catch (error) {
                    // A wrapper preserves even a thrown undefined value.
                    failure = { error }
                    pending.length = 0
                    input.off("data", data)
                    // Native abortion completes even when close events are disabled.
                    const controller = new AbortController()
                    addAbortSignal(controller.signal, input)
                    controller.abort(error)
                }
            }

            function complete(error) {
                input.off("data", data)
                pending.length = 0
                if (error !== undefined && error !== null && !input.destroyed) {
                    failure ??= { error }
                    const previousCleanup = cleanup
                    // Observe destruction before it marks an asynchronously destroyed stream errored.
                    cleanup = finished(input, { readable: true, writable: false }, complete)
                    previousCleanup()
                    input.destroy(error)
                    return
                }
                cleanup()
                if (failure !== undefined) {
                    reject(failure.error)
                } else if (error !== undefined && error !== null) {
                    reject(error)
                } else if (accumulated !== 0) {
                    reject(new WorkerError("Worker input ended inside a frame", "protocol"))
                } else {
                    resolve()
                }
            }

            cleanup = finished(input, { readable: true, writable: false }, complete)
            input.on("data", data)
        })
    }
}
