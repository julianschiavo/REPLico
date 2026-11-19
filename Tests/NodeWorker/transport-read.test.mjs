import assert from "node:assert/strict"
import { once } from "node:events"
import { Readable } from "node:stream"
import test from "node:test"
import { maximumFrameBytes, Transport } from "../../Sources/ReplicoCore/Resources/NodeWorker.bundle/transport.mjs"

function readable(options = {}) {
    return new Readable({
        read() {
        },
        ...options,
    })
}

function transport() {
    return new Transport(() => {
        assert.fail("read unexpectedly wrote an output frame")
    })
}

test("fragmented UTF-8 and multiple frames preserve order and JSON semantics", async () => {
    const input = readable()
    const values = []
    const reading = transport().read(input, value => values.push(value))
    const bytes = Buffer.from(' {"text":"😀界\\u0000"}\n\n \t\n{"next":1}\n')
    for (const byte of bytes) {
        input.push(Buffer.from([byte]))
    }
    input.push(null)
    await reading
    assert.deepEqual(values, [{ text: "😀界\u0000" }, { next: 1 }])
})

test("native UTF-8 replacement behavior remains unchanged", async () => {
    const input = Readable.from([Buffer.from('{"text":"'), Buffer.from([0xFF]), Buffer.from('"}\n')])
    const values = []
    await transport().read(input, value => values.push(value))
    assert.deepEqual(values, [{ text: "�" }])
})

test("a chunk's remaining frames precede reentrant input", async () => {
    const input = readable()
    const values = []
    const reading = transport().read(input, value => {
        values.push(value)
        if (value === 1) {
            input.push(Buffer.from("3\n"))
        } else if (value === 3) {
            input.push(null)
        }
    })
    input.push(Buffer.from("1\n2\n"))
    await reading
    assert.deepEqual(values, [1, 2, 3])
})

test("a receive result is not awaited", async () => {
    const input = Readable.from([Buffer.from("1\n2\n")])
    const values = []
    const never = new Promise(() => {
    })
    await transport().read(input, value => {
        values.push(value)
        return never
    })
    assert.deepEqual(values, [1, 2])
})

test("receive exceptions wait for native destruction and preserve the thrown value", async () => {
    let entered
    const destroying = new Promise(resolve => {
        entered = resolve
    })
    let finishDestroy
    const input = readable({
        destroy(error, callback) {
            finishDestroy = () => callback(error)
            entered()
        },
    })
    const expected = new Error("receive rejected the command")
    let settled = false
    const values = []
    const reading = transport().read(input, value => {
        values.push(value)
        throw expected
    })
    const rejection = assert.rejects(reading, error => error === expected)
    reading.then(() => {
        settled = true
    }, () => {
        settled = true
    })
    input.push(Buffer.from("1\n2\n"))
    await destroying
    assert.equal(input.destroyed, true)
    assert.equal(settled, false)
    finishDestroy()
    await rejection
    assert.deepEqual(values, [1])
})

test("malformed JSON rejects and destroys the stream", async () => {
    const input = Readable.from([Buffer.from("1\ninvalid\n2\n")])
    const values = []
    await assert.rejects(transport().read(input, value => values.push(value)), SyntaxError)
    assert.equal(input.destroyed, true)
    assert.deepEqual(values, [1])
})

test("receive exceptions settle when close events are disabled", async () => {
    const input = readable({ emitClose: false })
    const expected = new Error("receive failed without close events")
    const reading = transport().read(input, () => {
        throw expected
    })
    const rejection = assert.rejects(reading, error => error === expected)
    input.push(Buffer.from("1\n"))
    await rejection
    assert.equal(input.destroyed, true)
})

test("native errors reject with their original identity", async () => {
    const input = readable()
    const expected = new Error("native input failed")
    const reading = transport().read(input, () => {
        assert.fail("an incomplete frame was delivered")
    })
    const rejection = assert.rejects(reading, error => error === expected)
    input.push(Buffer.from('{"incomplete":'))
    input.destroy(expected)
    await rejection
    assert.equal(input.destroyed, true)
})

test("an error event on an open stream still destroys it", async () => {
    for (const emitClose of [true, false]) {
        let entered
        const destroying = new Promise(resolve => {
            entered = resolve
        })
        let finishDestroy
        const input = readable({
            emitClose,
            destroy(error, callback) {
                finishDestroy = () => callback(error)
                entered()
            },
        })
        const expected = new Error("open input failed")
        let settled = false
        const reading = transport().read(input, () => {
            assert.fail("no command was supplied")
        })
        const rejection = assert.rejects(reading, error => error === expected)
        reading.then(() => {
            settled = true
        }, () => {
            settled = true
        })
        input.emit("error", expected)
        await destroying
        assert.equal(input.destroyed, true)
        assert.equal(settled, false)
        finishDestroy()
        await rejection
    }
})

test("premature close rejects through the native stream error", async () => {
    const input = readable()
    const reading = transport().read(input, () => {
        assert.fail("no command was supplied")
    })
    const rejection = assert.rejects(reading, { code: "ERR_STREAM_PREMATURE_CLOSE" })
    input.destroy()
    await rejection
})

test("EOF rejects an unterminated frame including whitespace", async () => {
    for (const text of ['{"incomplete":1}', "   "]) {
        const input = Readable.from([Buffer.from(text)])
        await assert.rejects(transport().read(input, () => {
            assert.fail("an unterminated frame was delivered")
        }), { kind: "protocol", message: "Worker input ended inside a frame" })
    }
})

test("ordinary EOF does not force destruction when autoDestroy is disabled", async () => {
    const input = readable({ autoDestroy: false })
    const reading = transport().read(input, () => {
    })
    input.push(null)
    await reading
    assert.equal(input.destroyed, false)
    input.destroy()
})

test("already-ended and already-closed inputs settle", async () => {
    const ended = readable({ autoDestroy: false })
    ended.resume()
    ended.push(null)
    await once(ended, "end")
    await transport().read(ended, () => {
        assert.fail("no command was supplied")
    })
    ended.destroy()
    const closed = readable()
    closed.destroy()
    await once(closed, "close")
    await assert.rejects(transport().read(closed, () => {
        assert.fail("no command was supplied")
    }), { code: "ERR_STREAM_PREMATURE_CLOSE" })
})

test("read removes data and native completion listeners after clean EOF", async () => {
    const input = Readable.from([Buffer.from("1\n")])
    await transport().read(input, () => {
    })
    for (const event of ["data", "end", "error", "close"]) {
        assert.equal(input.listenerCount(event), 0, event)
    }
})

test("read preserves a thrown undefined value", async () => {
    const input = Readable.from([Buffer.from("1\n")])
    let rejected = false
    await transport().read(input, () => {
        throw undefined
    }).catch(error => {
        rejected = true
        assert.equal(error, undefined)
    })
    assert.equal(rejected, true)
    assert.equal(input.destroyed, true)
})

test("read accepts exactly the byte limit and rejects the next byte before parsing", async () => {
    const spaces = Buffer.alloc(1_024 * 1_024, 32)
    const exact = Readable.from([...Array(64).fill(spaces), Buffer.from("\n")])
    await transport().read(exact, () => {
        assert.fail("a whitespace line was delivered")
    })
    const oversized = Readable.from([...Array(64).fill(spaces), Buffer.from(" ")])
    await assert.rejects(transport().read(oversized, () => {
        assert.fail("an oversized frame was delivered")
    }), { kind: "protocol", message: "Worker input exceeds the frame limit" })
    assert.equal(oversized.destroyed, true)
})
