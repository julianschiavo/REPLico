import assert from "node:assert/strict"
import test from "node:test"
import { maximumFrameBytes, Transport } from "../../Sources/ReplicoCore/Resources/NodeWorker.bundle/transport.mjs"

test("output frames preserve Unicode and escaped text inside one JSON line", async () => {
    const frames = []
    const transport = new Transport((frame, completed) => {
        frames.push(frame)
        completed()
    })
    const content = { type: "text", text: "😀界\n\t\"\\\u0000" }
    await transport.send({ output: { executionID: "unicode", content } })
    assert.equal(frames.length, 1)
    assert.equal(frames[0].split("\n").length, 2)
    assert.deepEqual(JSON.parse(frames[0]), { output: { executionID: "unicode", content } })
})

test("frame limits count encoded UTF-8 bytes after text escaping", async () => {
    const transport = new Transport(() => {
        assert.fail("an oversized frame reached the writer")
    })
    const text = "\u0000".repeat(Math.floor(maximumFrameBytes / 6))
    await assert.rejects(transport.send({ output: { executionID: "oversized", content: { type: "text", text } } }), {
        kind: "protocol",
        message: "Worker output exceeds the frame limit",
    })
})

test("large text updates reconstruct independently produced outputs byte for byte", async () => {
    let emitted
    const transport = new Transport((frame, completed) => {
        emitted = JSON.parse(frame).output.content
        completed()
    })
    transport.textDeltas = true
    const side = "e\u0301松🧑‍🚀\n".repeat(8000)
    const values = [
        side + "first" + side, side + "second" + side, side + "💡" + side,
        side + "💡" + side, "x".repeat(70000), "y".repeat(70000), "\uD800".repeat(70000),
    ]
    let previous
    let changed = false
    for (const [index, text] of values.entries()) {
        await transport.send({ output: { executionID: String(index), content: { type: "text", text } } })
        if (emitted.update?.change) {
            changed = true
            const { base, key, prefix, suffix, insert } = emitted.update.change
            assert.equal(base, previous.key)
            const bytes = Buffer.concat([
                previous.bytes.subarray(0, prefix), Buffer.from(insert, "base64"),
                previous.bytes.subarray(previous.bytes.length - suffix),
            ])
            assert.deepEqual(bytes, Buffer.from(text))
            previous = { key, bytes }
        } else {
            assert.equal(emitted.text, text)
            if (emitted.update?.seed) {
                previous = { key: emitted.update.seed.key, bytes: Buffer.from(text) }
            }
        }
    }
    assert(changed)
    const named = { type: "text", text: values[0], itemID: "selection" }
    await transport.send({ output: { executionID: "named", content: named } })
    assert.deepEqual(emitted, named)
})
