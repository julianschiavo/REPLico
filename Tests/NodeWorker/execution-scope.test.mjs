import assert from "node:assert/strict"
import test from "node:test"
import { ExecutionScope, activeScope, executionStorage } from "../../Sources/ReplicoCore/Resources/NodeWorker.bundle/execution-scope.mjs"
import { ServiceBridge } from "../../Sources/ReplicoCore/Resources/NodeWorker.bundle/services.mjs"

test("helper draining includes nested helper work and rejects stale scope writes", async () => {
    const events = []
    const scope = new ExecutionScope({
        executionID: "original",
        send: async event => {
            events.push(event)
        },
        services: new ServiceBridge(async () => undefined),
        serviceNames: [],
        metadata: {},
        context: { cwd: "/project", homeDir: "/home/example", tmpDir: "/tmp", env: {} },
    })
    executionStorage.run(scope, () => {
        scope.track(async () => {
            scope.write("nested")
        })
    })
    await scope.drain()
    assert.deepEqual(events, [{ event: "output", executionID: "original", content: { type: "text", text: "nested" } }])
    scope.close()
    assert.throws(() => executionStorage.run(scope, () => activeScope().write("late")), error => {
        return error.kind === "stale_execution"
    })
    assert.throws(() => scope.write("late"), error => {
        return error.kind === "stale_execution"
    })
    assert.throws(() => scope.log(["late"]), error => {
        return error.kind === "stale_execution"
    })
    assert.equal(events.length, 1)
})

test("request metadata and context are cloned and deeply frozen without serialization", () => {
    const metadata = { nested: { value: 1 } }
    const context = { cwd: "/project", homeDir: "/home/example", tmpDir: "/tmp", env: { KEY: "original" } }
    const scope = new ExecutionScope({
        executionID: "immutable",
        send: async () => undefined,
        services: new ServiceBridge(async () => undefined),
        serviceNames: [],
        metadata,
        context,
    })
    metadata.nested.value = 2
    context.env.KEY = "changed"
    assert.equal(scope.metadata.nested.value, 1)
    assert.equal(scope.context.env.KEY, "original")
    assert.throws(() => {
        scope.metadata.nested.value = 3
    }, TypeError)
    assert.throws(() => {
        scope.context.env.KEY = "changed"
    }, TypeError)
    scope.close()
})

test("a write during output starts the next group with its own console separators", async () => {
    const output = []
    const scope = new ExecutionScope({
        executionID: "console",
        send: async ({ content }) => {
            output.push(content.text)
            if (output.length === 1) {
                scope.log(["second"])
            }
        },
    })
    scope.log(["first"])
    await scope.drain()
    scope.write("third")
    await scope.drain()
    assert.deepEqual(output, ["first", "second\nthird"])
})

test("text writes count each UTF-8 fragment and console separator at the shared output limit", async () => {
    const events = []
    const scope = new ExecutionScope({
        executionID: "byte-budget",
        send: async event => events.push(event.content),
        serviceNames: [],
        context: {},
    })
    const prefix = "x".repeat(64 * 1024 * 1024 - 14)
    scope.write(prefix, "prefix")
    scope.log(["\u007f"])
    scope.write("\u0080")
    scope.write("\uD800")
    scope.write("\uDC00")
    scope.write("🙂")
    assert.throws(() => scope.write("x"), error => error.kind === "output_limit")
    scope.write("")
    await scope.drain()
    assert.deepEqual(events, [
        { type: "text", text: prefix, itemID: "prefix" },
        { type: "text", text: "\u007f\n\u0080\uD800\uDC00🙂" },
    ])
})

test("service replies reject unknown requests and mismatched execution ownership", async () => {
    const bridge = new ServiceBridge(async () => undefined)
    const pending = bridge.invoke({ executionID: "owner", requestID: "known", service: "example", request: null })
    assert.throws(() => {
        bridge.reply({ executionID: "different", requestID: "known", ok: true, value: 1 })
    }, error => {
        return error.kind === "stale_execution"
    })
    bridge.reply({ executionID: "owner", requestID: "known", ok: true, value: 2 })
    assert.equal(await pending, 2)
    assert.throws(() => {
        bridge.reply({ executionID: "owner", requestID: "known", ok: true, value: 3 })
    }, error => {
        return error.kind === "stale_execution"
    })
})
