import assert from "node:assert/strict"
import test from "node:test"
import { imageContent } from "../../Sources/ReplicoCore/Resources/NodeWorker.bundle/images.mjs"

const malformedURL = "Images require a PNG, JPEG, WebP, or GIF data URL or a file URL"
const malformedImage = "Image bytes must match the specified PNG, JPEG, WebP, or GIF format"

test("data URLs retain permissive native base64 decoding", async () => {
    const encoded = Buffer.from([255, 216, 255, 0, 0, 0]).toString("base64")
    for (const payload of [encoded, encoded + "=", encoded + "==", encoded + "A", encoded + "AB", encoded + "AB="]) {
        const actual = await imageContent("data:image/jpeg;base64," + payload)
        assert.deepEqual(actual, {
            type: "image", mimeType: "image/jpeg", data: Buffer.from(payload, "base64").toString("base64"),
        })
    }
})

test("line terminators and misplaced padding remain malformed data URLs", async () => {
    const encoded = Buffer.from([255, 216, 255, 0, 0, 0]).toString("base64")
    for (const suffix of ["\n", "\r", "\r\n", "\u2028", "\u2029", "\u0085", " ", "\t", "===", "=A", "==A"]) {
        await assert.rejects(imageContent("data:image/jpeg;base64," + encoded + suffix), {
            kind: "image", message: malformedURL,
        })
    }
})

test("ignored characters and interior padding cannot shorten an otherwise valid quartet", async () => {
    for (const payload of [
        "/9j/    AAAA", "/9j/AA\tA", "/9j/AA==AAAA", "/9j/AA==BB=", "/9j/AAA===",
        "/9j/ABB!", "/9j/AAAA\u00a0AA", "/9j/🎨AA",
    ]) {
        await assert.rejects(imageContent("data:image/jpeg;base64," + payload), {
            kind: "image", message: malformedURL,
        })
    }
})

test("each possible final sextet preserves native byte and padding normalization", async () => {
    for (const digit of "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/") {
        for (const prefix of ["", "A", "AA", "AAA"]) {
            for (const padding of ["", "=", "=="]) {
                const encoded = "/9j/" + prefix + digit + padding
                const image = await imageContent("data:image/jpeg;base64," + encoded)
                assert.equal(image.data, Buffer.from(encoded, "base64").toString("base64"))
            }
        }
    }
})

test("empty and short base64 payloads retain image-format error ordering", async () => {
    for (const payload of ["", "=", "==", "A", "AA", "AAA", "A=", "AA=", "AAA=="]) {
        await assert.rejects(imageContent("data:image/jpeg;base64," + payload), {
            kind: "image", message: malformedImage,
        })
    }
    for (const header of ["DATA:image/jpeg;base64,", "data:image/JPEG;base64,", "data:image/jpeg;BASE64,", "data:image/jpg;base64,", "data:image/jpeg;charset=utf8;base64,"]) {
        await assert.rejects(imageContent(header + "/9j/"), { kind: "image", message: malformedURL })
    }
})

test("data URL syntax is rejected before oversized decoded-image limits", async () => {
    const bytes = Buffer.alloc(8 * 1024 * 1024 + 1)
    bytes.set([255, 216, 255])
    const encoded = bytes.toString("base64")
    await assert.rejects(imageContent("data:image/jpeg;base64," + encoded), {
        kind: "image", message: "Images must not exceed 8 MiB",
    })
    await assert.rejects(imageContent("data:image/jpeg;base64," + encoded + "!"), {
        kind: "image", message: malformedURL,
    })
})
