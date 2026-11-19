import assert from "node:assert/strict"
import test from "node:test"
import { imageContent } from "../../Sources/ReplicoCore/Resources/NodeWorker.bundle/images.mjs"
import { Transport } from "../../Sources/ReplicoCore/Resources/NodeWorker.bundle/transport.mjs"

test("large image frames preserve arbitrary string IDs and independently produced media bytes", async () => {
    const lines = []
    const transport = new Transport((line, done) => {
        lines.push(line)
        done()
    })
    const id = '👋\n"\\'
    for (const size of [24, 65535, 65536, 65537, 65538]) {
        const bytes = Buffer.alloc(size, 255)
        bytes[1] = 216
        const data = bytes.toString("base64")
        for (const input of [bytes, { bytes, mimeType: "image/jpeg" }, "data:image/jpeg;base64," + data]) {
            const content = await imageContent(input)
            await transport.sendImage(id, content)
            assert.equal(lines.pop(), JSON.stringify({ output: { executionID: id, content } }) + "\n")
        }
    }
})

test("lookalikes, additional fields and mutable copies retain JSON serialization", async () => {
    const lines = []
    const transport = new Transport((line, done) => {
        lines.push(line)
        done()
    })
    const bytes = Buffer.alloc(1 << 17, 255)
    bytes[1] = 216
    const image = await imageContent(bytes)
    const fake = Object.freeze({ ...image, data: '"\n\\', extra: "preserve" })
    await transport.sendImage("id", fake)
    assert.deepEqual(JSON.parse(lines.pop()), { output: { executionID: "id", content: fake } })
    const custom = {
        ...image,
        toJSON() {
            return { type: "text", text: "custom" }
        },
    }
    await transport.sendImage("id", custom)
    assert.deepEqual(JSON.parse(lines.pop()), { output: { executionID: "id", content: { type: "text", text: "custom" } } })
    const extended = { output: { executionID: "id", content: image, extra: "preserve" }, version: 2 }
    await transport.send(extended)
    assert.deepEqual(JSON.parse(lines.pop()), extended)
    await transport.sendImage(undefined, image)
    assert.deepEqual(JSON.parse(lines.pop()), { output: { content: image } })
    const malformed = 'data:image/jpeg;base64,' + image.data + '"x"'
    await assert.rejects(imageContent(malformed), { kind: "image" })
})

test("acknowledged image writes settle before the next acknowledged text write", async () => {
    const bytes = Buffer.alloc(65536, 255)
    bytes[1] = 216
    const large = await imageContent(bytes)
    const small = await imageContent(bytes.subarray(0, 3))
    for (const content of [large, small, { ...large }]) {
        for (const failure of [undefined, new Error("image write failed")]) {
            const callbacks = []
            const settled = []
            const transport = new Transport((_frame, completed) => callbacks.push(completed))
            const image = transport.sendImage("id", content).then(
                () => settled.push("image"),
                error => {
                    assert.equal(error, failure)
                    settled.push("failed image")
                },
            )
            const text = transport.send({ output: { executionID: "id", content: { type: "text", text: "done" } } })
                .then(() => settled.push("text"))
            assert.equal(callbacks.length, 2)
            callbacks[0](failure)
            callbacks[1]()
            await Promise.all([image, text])
            assert.deepEqual(settled, [failure === undefined ? "image" : "failed image", "text"])
        }
    }
})

test("negotiated image frames retain the original bytes and the write acknowledgment", async () => {
    const id = "A9137D55-B93F-45E3-850A-DAA18EE53FD0"
    const original = Buffer.alloc(65536, 10)
    original.set([255, 216, 255])
    const bytes = Buffer.from(original)
    const image = await imageContent(bytes)
    bytes.fill(0)
    let frame
    let acknowledge
    const transport = new Transport((data, done) => {
        frame = data
        acknowledge = done
    })
    transport.binaryImages = true
    const sent = transport.sendImage(id, image)
    assert.equal(frame[0], 0)
    assert.equal(frame.readUInt32BE(1), 37 + original.length)
    assert.equal(frame.subarray(5, 41).toString("ascii"), id)
    assert.equal(frame[41], 0)
    assert.equal(frame.at(-1), 10)
    assert.deepEqual(frame.subarray(42, -1), original)
    const error = new Error("Image destination closed")
    acknowledge(error)
    await assert.rejects(sent, error)

    // Arbitrary string identifiers continue to use JSON, including a UUID followed by LF.
    const differentID = id + "\n"
    const fallback = transport.sendImage(differentID, image)
    assert.equal(JSON.parse(frame).output.executionID, differentID)
    acknowledge()
    await fallback
})
