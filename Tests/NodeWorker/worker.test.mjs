import assert from "node:assert/strict"
import { spawn } from "node:child_process"
import { once } from "node:events"
import { tmpdir } from "node:os"
import path from "node:path"
import test from "node:test"
import { fileURLToPath } from "node:url"

const workerPath = fileURLToPath(new URL("../../Sources/ReplicoCore/Resources/NodeWorker.bundle/worker.mjs", import.meta.url))

class WorkerClient {
    #child
    #evaluation
    #events = []
    #waiting = []
    #buffer = ""
    #exited
    #exitResult
    #stderr = ""

    constructor() {
        this.#child = spawn(process.execPath, ["--experimental-vm-modules", "--experimental-import-meta-resolve", workerPath], {
            cwd: path.dirname(workerPath),
            stdio: ["pipe", "pipe", "pipe"],
        })
        this.#exited = once(this.#child, "exit").then(result => {
            this.#exitResult = result
            const error = new Error(`Worker exited: ${result.join(", ")}; ${this.#stderr}`)
            this.#evaluation?.reject(error)
            this.#evaluation = undefined
            for (const waiting of this.#waiting.splice(0)) {
                waiting.reject(error)
            }
            return result
        })
        this.#child.stderr.setEncoding("utf8")
        this.#child.stderr.on("data", chunk => {
            this.#stderr += chunk
        })
        this.#child.stdout.setEncoding("utf8")
        this.#child.stdout.on("data", chunk => {
            this.#buffer += chunk
            for (;;) {
                const newline = this.#buffer.indexOf("\n")
                if (newline === -1) {
                    break
                }
                const message = JSON.parse(this.#buffer.slice(0, newline))
                this.#buffer = this.#buffer.slice(newline + 1)
                const cases = Object.entries(message)
                assert.equal(cases.length, 1)
                const [event, payload] = cases[0]
                if (event === "completed") {
                    const evaluation = this.#evaluation
                    assert.equal(evaluation.executionID, payload.executionID)
                    this.#evaluation = undefined
                    evaluation.resolve(payload)
                    for (const waiting of this.#waiting.splice(0)) {
                        waiting.reject(new Error(`Evaluation completed before the expected event: ${payload.error?.message}`))
                    }
                } else {
                    const value = { event, ...payload }
                    const waiting = this.#waiting.shift()
                    if (waiting === undefined) {
                        this.#events.push(value)
                    } else {
                        waiting.resolve(value)
                    }
                }
            }
        })
    }

    evaluate(parameters, executionID) {
        assert.equal(this.#evaluation, undefined)
        const result = new Promise((resolve, reject) => {
            this.#evaluation = { executionID, resolve, reject }
            this.send({ evaluate: { ...parameters, executionID } })
        })
        result.catch(() => undefined)
        return result
    }

    reply(parameters, executionID) {
        this.send({ serviceReply: { ...parameters, executionID } })
    }

    send(command) {
        this.#child.stdin.write(`${JSON.stringify(command)}\n`)
    }

    nextEvent() {
        const event = this.#events.shift()
        if (event !== undefined) {
            return Promise.resolve(event)
        }
        return new Promise((resolve, reject) => {
            this.#waiting.push({ resolve, reject })
        })
    }

    async close() {
        if (this.#exitResult === undefined) {
            if (this.#evaluation !== undefined) {
                this.#child.kill("SIGTERM")
            } else {
                this.#child.stdin.end()
            }
        }
        return this.#exited
    }
}

function parameters(source, serviceNames = []) {
    return {
        code: source,
        metadata: { source: "test" },
        context: { cwd: path.dirname(workerPath), homeDir: "/home/example", tmpDir: tmpdir(), env: {} },
        serviceNames,
        moduleDirectories: [],
    }
}

test("an unknown source slot fails before evaluation", async t => {
    const client = new WorkerClient()
    t.after(() => client.close())
    await client.nextEvent()
    const evaluating = client.evaluate(parameters(0), "missing-source")
    const event = await client.nextEvent()
    assert.equal(event.event, "fatal")
    assert.match(event.error.message, /source slot/)
    await assert.rejects(evaluating, /Worker exited/)
})

test("worker startup, raw evaluation, output, and EOF shutdown use enum JSONL framing", async t => {
    const client = new WorkerClient()
    t.after(async () => {
        await client.close()
    })
    const ready = await client.nextEvent()
    assert.equal(ready.event, "ready")
    assert.equal(ready.version, 1)
    const result = await client.evaluate(parameters("await Promise.resolve(1n); console.log('one'); await nodeRepl.write('two', 'example');"), "output")
    assert.equal(result.succeeded, true)
    assert.deepEqual(await client.nextEvent(), { event: "output", executionID: "output", content: { type: "text", text: "two", itemID: "example" } })
    assert.deepEqual(await client.nextEvent(), { event: "output", executionID: "output", content: { type: "text", text: "one" } })
})

test("one-way service replies resolve only their originating execution", async t => {
    const client = new WorkerClient()
    t.after(async () => {
        await client.close()
    })
    await client.nextEvent()
    const evaluating = client.evaluate(parameters("const response = await nodeRepl.rpc('example', { value: 7 }); await nodeRepl.write(response);", ["example"]), "service")
    const service = await client.nextEvent()
    assert.equal(service.event, "service")
    assert.equal(service.executionID, "service")
    assert.deepEqual(service.request, { value: 7 })
    client.reply({ requestID: service.requestID, ok: true, value: "returned" }, "service")
    const result = await evaluating
    assert.equal(result.succeeded, true)
    assert.equal((await client.nextEvent()).content.text, "returned")
    client.reply({ requestID: service.requestID, ok: true, value: "again" }, "service")
    const recovered = await client.evaluate(parameters("await nodeRepl.write('after-stale');"), "after-stale")
    assert.equal(recovered.succeeded, true, recovered.error?.message)
    assert.equal((await client.nextEvent()).content.text, "after-stale")
})

test("overlapping evaluations are rejected instead of entering another scheduling queue", async t => {
    const client = new WorkerClient()
    t.after(async () => {
        await client.close()
    })
    await client.nextEvent()
    const evaluating = client.evaluate(parameters("await nodeRepl.rpc('example', {})", ["example"]), "active")
    assert.equal((await client.nextEvent()).event, "service")
    client.send({ evaluate: { ...parameters("throw Error('must not execute')"), executionID: "overlap" } })
    const fatal = await client.nextEvent()
    assert.equal(fatal.event, "fatal")
    assert.equal(fatal.error.kind, "protocol")
    await assert.rejects(evaluating, /Worker exited/)
    assert.equal((await client.close())[0], 1)
})

test("invalid RPC payloads reject before service dispatch and leave the kernel usable", async t => {
    const client = new WorkerClient()
    t.after(async () => {
        await client.close()
    })
    await client.nextEvent()
    const evaluating = client.evaluate(parameters(`
const kept = 42;
const cycle = {};
cycle.self = cycle;
const invalid = [undefined, function missing() {
}, Symbol('missing'), { toJSON() {
    return undefined;
} }, cycle, 1n];
let rejected = 0;
for (const payload of invalid) {
    try {
        await nodeRepl.rpc('example', payload);
        throw Error('invalid request was dispatched');
    } catch (error) {
        if (error.name !== 'TypeError') throw error;
        rejected += 1;
    }
}
await nodeRepl.write(rejected);
`, ["example"]), "invalid-service")
    const output = await client.nextEvent()
    assert.equal(output.event, "output")
    assert.equal(output.content.text, "6")
    const result = await evaluating
    assert.equal(result.succeeded, true, result.error?.message)
    const recovered = await client.evaluate(parameters("await nodeRepl.write(kept);"), "after-invalid-service")
    assert.equal(recovered.succeeded, true, recovered.error?.message)
    const nextOutput = await client.nextEvent()
    assert.equal(nextOutput.event, "output")
    assert.equal(nextOutput.executionID, "after-invalid-service")
    assert.equal(nextOutput.content.text, "42")
})

test("RPC payloads use native Date and toJSON normalization once at the wire boundary", async t => {
    const client = new WorkerClient()
    t.after(async () => {
        await client.close()
    })
    await client.nextEvent()
    const evaluating = client.evaluate(parameters(`
await nodeRepl.rpc('example', new Date('2026-11-16T12:00:00.000Z'));
let jsonCalls = 0;
await nodeRepl.rpc('example', { toJSON() {
    jsonCalls += 1;
    return { date: new Date('2026-11-16T12:00:00.000Z'), omitted: undefined, values: [undefined, Symbol('omitted')] };
} });
await nodeRepl.write(jsonCalls);
`, ["example"]), "normalized-service")
    const date = await client.nextEvent()
    assert.equal(date.event, "service")
    assert.equal(date.request, "2026-11-16T12:00:00.000Z")
    client.reply({ requestID: date.requestID, ok: true, value: null }, "normalized-service")
    const normalized = await client.nextEvent()
    assert.equal(normalized.event, "service")
    assert.deepEqual(normalized.request, { date: "2026-11-16T12:00:00.000Z", values: [null, null] })
    client.reply({ requestID: normalized.requestID, ok: true, value: null }, "normalized-service")
    const output = await client.nextEvent()
    assert.equal(output.event, "output")
    assert.equal(output.content.text, "1")
    const result = await evaluating
    assert.equal(result.succeeded, true, result.error?.message)
})

test("fatal asynchronous failures emit an attributed event and terminate the worker", async () => {
    const client = new WorkerClient()
    await client.nextEvent()
    const evaluating = client.evaluate(parameters("queueMicrotask(() => { throw Error('asynchronous failure'); }); await new Promise(() => {});"), "fatal")
    evaluating.catch(() => undefined)
    const event = await client.nextEvent()
    assert.equal(event.event, "fatal")
    assert.equal(event.executionID, "fatal")
    assert.equal(event.error.message, "asynchronous failure")
    await assert.rejects(evaluating, /Worker exited/)
    const result = await client.close()
    assert.equal(result[0], 1)
})

test("a promise rejected in a later cell reports the execution that created it", async t => {
    const client = new WorkerClient()
    t.after(() => client.close())
    await client.nextEvent()
    const created = await client.evaluate(parameters(`
let rejectLater
const pending = new Promise((resolve, reject) => {
    rejectLater = reject
})

`), "creator")
    assert.equal(created.succeeded, true)
    const rejecting = client.evaluate(parameters(`
rejectLater(Error("rejected from another cell"))
await new Promise(() => {})
`), "rejector")
    const event = await client.nextEvent()
    assert.equal(event.event, "fatal")
    assert.equal(event.executionID, "creator")
    assert.equal(event.error.message, "rejected from another cell")
    await assert.rejects(rejecting, /Worker exited/)
})

test("worker configuration survives a syntax error in the first cell", async t => {
    const client = new WorkerClient()
    t.after(() => client.close())
    await client.nextEvent()
    const context = parameters("").context
    const invalid = await client.evaluate({
        code: "const =",
        startup: { context, startupSource: "", serviceNames: ["example"] },
    }, "invalid")
    assert.equal(invalid.succeeded, false)
    const next = client.evaluate({
        code: "nodeRepl.write([nodeRepl.cwd, typeof nodeRepl.rpc, nodeRepl.requestMeta.tag].join('|'))",
        metadata: { tag: "fresh" },
    }, "next")
    assert.equal((await next).succeeded, true)
    assert.equal((await client.nextEvent()).content.text, context.cwd + "|function|fresh")
})
