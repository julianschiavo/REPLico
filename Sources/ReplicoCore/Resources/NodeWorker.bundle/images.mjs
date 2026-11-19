import { readFile } from "node:fs/promises"
import { fileURLToPath } from "node:url"
import { WorkerError } from "./errors.mjs"

const maximumImageBytes = 8 * 1024 * 1024

const largeImages = new WeakMap()
const toBase64 = Function.prototype.call.bind(Uint8Array.prototype.toBase64)
const fromBase64 = Uint8Array.fromBase64.bind(Uint8Array)

// Only imageContent creates these immutable snapshots. Other objects retain normal JSON encoding.
export function imageBytes(content) {
    return largeImages.get(content)
}

export async function imageContent(input) {
    let bytes
    let data
    let mimeType
    if (typeof input === "string") {
        if (input.startsWith("file:")) {
            bytes = await readFile(fileURLToPath(input))
        } else {
            const header = /^data:(image\/(?:png|jpeg|webp|gif));base64,/.exec(input)
            const normalized = header && normalizedBase64(input.slice(header[0].length))
            if (!normalized) {
                throw new WorkerError("Images require a PNG, JPEG, WebP, or GIF data URL or a file URL", "image")
            }
            mimeType = header[1]
            bytes = normalized.bytes
            data = normalized.data
        }
    } else if (ArrayBuffer.isView(input)) {
        bytes = Buffer.from(input.buffer, input.byteOffset, input.byteLength)
    } else if (Object.prototype.toString.call(input) === "[object ArrayBuffer]") {
        bytes = Buffer.from(input)
    } else if (input !== null && typeof input === "object") {
        if (!ArrayBuffer.isView(input.bytes)) {
            throw new WorkerError("Image bytes must be an ArrayBuffer view", "image")
        }
        bytes = Buffer.from(input.bytes.buffer, input.bytes.byteOffset, input.bytes.byteLength)
        mimeType = input.mimeType
    } else {
        throw new WorkerError("Unsupported image input", "image")
    }
    const byteCount = bytes.length
    if (byteCount > maximumImageBytes) {
        throw new WorkerError("Images must not exceed 8 MiB", "image")
    }
    const detectedType = detectImageType(bytes)
    if (detectedType === undefined || (mimeType !== undefined && mimeType !== detectedType)) {
        throw new WorkerError("Image bytes must match the specified PNG, JPEG, WebP, or GIF format", "image")
    }
    if (byteCount < 64 * 1024) {
        return { type: "image", data: data ?? toBase64(bytes), mimeType: detectedType }
    }
    const snapshot = typeof input === "string" ? bytes : Buffer.from(bytes)
    const content = Object.freeze({
        type: "image",
        get data() {
            return data ??= toBase64(snapshot)
        },
        mimeType: detectedType,
    })
    largeImages.set(content, snapshot)
    return content
}

// Validate full quartets in Node's native decoder. Their decoded length is exact
// only if every character is a base64 digit. Node permits a short or overpadded
// final quartet, so normalize just those final digits with Buffer.
function normalizedBase64(encoded) {
    const digits = encoded.length - (encoded.endsWith("==") ? 2 : encoded.endsWith("=") ? 1 : 0)
    const split = digits - digits % 4
    const tail = encoded.slice(split, digits)
    if (/[^A-Za-z0-9+/]/.test(tail)) {
        return
    }
    let prefix
    try {
        prefix = fromBase64(encoded.slice(0, split), { lastChunkHandling: "strict" })
        if (prefix.length !== split / 4 * 3) {
            return
        }
    } catch (error) {
        if (error instanceof SyntaxError) {
            return
        }
        throw error
    }
    const bytes = Buffer.from(prefix.buffer, prefix.byteOffset, prefix.byteLength)
    if (split === encoded.length) {
        return { bytes, data: encoded }
    }
    const end = Buffer.from(tail, "base64")
    const canonical = toBase64(end)
    return {
        bytes: end.length ? Buffer.concat([bytes, end]) : bytes,
        data: encoded.slice(split) === canonical ? encoded : encoded.slice(0, split) + canonical,
    }
}

function detectImageType(bytes) {
    if (bytes.length >= 8 && bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) {
        return "image/png"
    }
    if (bytes.length >= 3 && bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255) {
        return "image/jpeg"
    }
    if (bytes.length >= 12 && bytes.toString("ascii", 0, 4) === "RIFF" && bytes.toString("ascii", 8, 12) === "WEBP") {
        return "image/webp"
    }
    if (bytes.length >= 6 && (bytes.toString("ascii", 0, 6) === "GIF87a" || bytes.toString("ascii", 0, 6) === "GIF89a")) {
        return "image/gif"
    }
    return undefined
}
