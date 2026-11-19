import assert from "node:assert/strict"
import { mkdtemp, mkdir, rm, symlink, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import path from "node:path"
import test from "node:test"
import { pathToFileURL } from "node:url"
import { createRuntimeContext } from "../../Sources/ReplicoCore/Resources/NodeWorker.bundle/context.mjs"
import { Kernel } from "../../Sources/ReplicoCore/Resources/NodeWorker.bundle/kernel.mjs"
import { ServiceBridge } from "../../Sources/ReplicoCore/Resources/NodeWorker.bundle/services.mjs"

function harness(cwd = process.cwd()) {
    const events = []
    const services = new ServiceBridge(async event => {
        events.push(event)
    })
    const kernel = new Kernel({ cwd, services, send: async event => {
        events.push(event)
    } })
    return { kernel, events, services, cwd }
}

function parameters(code, cwd = process.cwd(), moduleDirectories = []) {
    return {
        code,
        metadata: { request: "one" },
        context: { cwd, homeDir: "/home/example", tmpDir: tmpdir(), env: { EXAMPLE: "value" } },
        serviceNames: [],
        moduleDirectories,
    }
}

test("BigInt and RegExp syntax compile with top-level await and persist their values", async () => {
    const { kernel, events } = harness()
    const first = await kernel.evaluate("first", parameters("const amount = 123n; const pattern = /test/gu; await Promise.resolve(); await nodeRepl.write([String(amount), pattern.test('test')]);"))
    assert.equal(first.succeeded, true, first.error?.message)
    const second = await kernel.evaluate("second", parameters("await nodeRepl.write(amount === 123n);"))
    assert.equal(second.succeeded, true, second.error?.message)
    assert.deepEqual(events.map(event => event.content.text), ["[ '123', true ]", "true"])
})

test("bindings persist automatically and normal expressions emit nothing", async () => {
    const { kernel, events } = harness()
    const first = await kernel.evaluate("first", parameters("let value = 41;"))
    assert.equal(first.succeeded, true, first.error?.message)
    assert.equal(events.length, 0)
    const second = await kernel.evaluate("second", parameters("value += 1; await nodeRepl.write(value);"))
    assert.equal(second.succeeded, true, second.error?.message)
    assert.deepEqual(events.map(event => event.content.text), ["42"])
    assert.equal(events[0].executionID, "second")
})

test("constants can be redeclared with const and reject assignments", async () => {
    const { kernel, events } = harness()
    assert.equal((await kernel.evaluate("first", parameters("const amount = 1; const read = () => amount"))).succeeded, true)
    const assignment = await kernel.evaluate("assignment", parameters("amount = 2"))
    assert.equal(assignment.succeeded, false)
    assert.match(assignment.error.message, /constant variable/)
    assert.equal((await kernel.evaluate("again", parameters("const amount = 3; nodeRepl.write(read())"))).succeeded, true)
    const changedKind = await kernel.evaluate("kind", parameters("let amount = 4"))
    assert.equal(changedKind.succeeded, false)
    assert.deepEqual(events.map(event => event.content.text), ["3"])
})

test("source validation precedes execution and dynamic imports remain available", async () => {
    const { kernel, events } = harness()
    for (const code of [
        'nodeRepl.write(1); import x from "node:path"',
        'nodeRepl.write(2); export const x = 0',
        'nodeRepl.write(3); import.meta',
        'nodeRepl.write(4); if (true)',
        'nodeRepl.write(5); label:',
    ]) {
        assert.equal((await kernel.evaluate("syntax", parameters(code))).succeeded, false)
    }
    const dynamic = await kernel.evaluate("dynamic", parameters("nodeRepl.write((await import('node:path')).posix.sep)"))
    assert.equal(dynamic.succeeded, true, dynamic.error?.message)
    assert.deepEqual(events.map(event => event.content.text), ["/"])
})

test("discarding a final expression does not inspect or await its value", async () => {
    const { kernel, events } = harness()
    const first = await kernel.evaluate("thenable", parameters(`
        let inspected = false
        ;({ get then() { inspected = true; throw Error("unexpected await") } })
    `))
    assert.equal(first.succeeded, true, first.error?.message)
    const next = await kernel.evaluate("check", parameters("nodeRepl.write(inspected)"))
    assert.equal(next.succeeded, true, next.error?.message)
    assert.deepEqual(events.map(event => event.content.text), ["false"])
})

test("native hoisting preserves var and function declarations after a throw", async () => {
    const { kernel, events } = harness()
    const failed = await kernel.evaluate("stop", parameters("let completed = '💬'; throw Error('stop'); var later = 7; function read() { return completed }"))
    assert.equal(failed.succeeded, false)
    const recovered = await kernel.evaluate("read", parameters("nodeRepl.write([read(), later])"))
    assert.equal(recovered.succeeded, true, recovered.error?.message)
    assert.equal(events[0].content.text, "[ '💬', undefined ]")
})

test("failed cells commit initialized values and retain preceding uninitialized bindings", async () => {
    const { kernel, events } = harness()
    const first = await kernel.evaluate("first", parameters("let value = 1;"))
    assert.equal(first.succeeded, true, first.error?.message)
    const failed = await kernel.evaluate("failed", parameters("let completed = 2; throw new Error('stop'); let value = 3;"))
    assert.equal(failed.succeeded, false)
    const recovered = await kernel.evaluate("check", parameters("await nodeRepl.write([completed, value]);"))
    assert.equal(recovered.succeeded, true, recovered.error?.message)
    assert.equal(events[0].content.text, "[ 2, 1 ]")
})

test("special binding names and failed redeclarations retain native values", async () => {
    const { kernel, events } = harness()
    const first = await kernel.evaluate("carrier-first", parameters(`
let __proto__ = { value: 1 };
let constructor = 42;
const toString = 'own binding';
const earlier = () => constructor;
`))
    assert.equal(first.succeeded, true, first.error?.message)
    const second = await kernel.evaluate("carrier-second", parameters("__proto__.value = 2; constructor += 1;"))
    assert.equal(second.succeeded, true, second.error?.message)
    const failed = await kernel.evaluate("carrier-failed", parameters("__proto__.value = 3; let constructor = (() => { throw Error('initializer'); })();"))
    assert.equal(failed.succeeded, false)
    const recovered = await kernel.evaluate("carrier-check", parameters("await nodeRepl.write([__proto__.value, constructor, toString, earlier()]);"))
    assert.equal(recovered.succeeded, true, recovered.error?.message)
    assert.equal(events[0].content.text, "[ 3, 43, 'own binding', 43 ]")
})

test("interleaved cells retain unused values, older closures and fresh request metadata", async () => {
    const { kernel, events } = harness()
    const installed = await kernel.evaluate("cache-seed", parameters("let value = 1; let unused = 19; const object = { count: 1 }; const read = () => value"))
    assert.equal(installed.succeeded, true, installed.error?.message)
    const change = "value += 1; object.count += 1; nodeRepl.write(JSON.stringify([value, read(), object.count, nodeRepl.requestMeta.request]))"
    const observe = "nodeRepl.write(JSON.stringify([unused, value, read(), object.count, nodeRepl.requestMeta.request]))"
    for (const [index, code] of [change, observe, change, observe].entries()) {
        const result = await kernel.evaluate("cache-" + index, { ...parameters(code), metadata: { request: index } })
        assert.equal(result.succeeded, true, result.error?.message)
    }
    const failed = await kernel.evaluate("cache-failed", parameters("let value = missing(); var ghost = 3"))
    assert.equal(failed.succeeded, false)
    const recovered = await kernel.evaluate("cache-recovered", { ...parameters(change), metadata: { request: "recovered" } })
    assert.equal(recovered.succeeded, true, recovered.error?.message)
    assert.deepEqual(events.map(event => event.content.text), [
        '[2,2,2,0]', '[19,2,2,2,1]', '[3,3,3,2]', '[19,3,3,3,3]', '[4,4,4,"recovered"]',
    ])
    const fresh = harness()
    const isolated = await fresh.kernel.evaluate("fresh-cache", parameters("nodeRepl.write(typeof value)"))
    assert.equal(isolated.succeeded, true, isolated.error?.message)
    assert.equal(fresh.events[0].content.text, "undefined")
})

test("hashbang cells reject consistently before and after persistent declarations", async () => {
    for (const seed of [undefined, "let unused = 1", "let used = 1"]) {
        const { kernel } = harness()
        if (seed !== undefined) {
            assert.equal((await kernel.evaluate("hashbang-seed", parameters(seed))).succeeded, true)
        }
        for (const code of ["#!/usr/bin/env node", "#!/usr/bin/env node\nvoid 0", "#!/usr/bin/env node\nnodeRepl.write(used)"]) {
            const result = await kernel.evaluate("hashbang", parameters(code))
            assert.equal(result.succeeded, false)
            assert.deepEqual(result.error, { message: "Invalid or unexpected token", kind: "syntax" })
        }
    }
})

test("selective bindings reach nested defaults, class fields and computed assignment targets", async () => {
    const { kernel, events } = harness()
    const cells = [
        "let value = 7; const key = 'value'; const source = { value: 11 }",
        `function read({[key]: first = value} = source, next = () => value) {
    return [first, next()]
}
class Container {
    field = value
    static item = source[key]
    static {
        this.result = value
    }
}`,
        "void 0",
        "try { throw 9 } catch (value) { value++ }; nodeRepl.write(JSON.stringify([read(), new Container().field, Container.item, Container.result, typeof value, {value}]))",
        "({value} = {value: 3}); for (value of [4, 5]) {}; [value = 6] = []; nodeRepl.write(JSON.stringify([value, key, read()]))",
    ]
    for (const [index, code] of cells.entries()) {
        const result = await kernel.evaluate("scope-" + index, parameters(code))
        assert.equal(result.succeeded, true, result.error?.message)
    }
    assert.deepEqual(events.map(event => event.content.text), ['[[11,7],7,11,7,"number",{"value":7}]', '[6,"value",[11,6]]'])
})

test("syntax failures preserve the existing namespace", async () => {
    const { kernel, events } = harness()
    await kernel.evaluate("first", parameters("const stable = 7;"))
    const invalid = await kernel.evaluate("invalid", parameters("let ="))
    assert.equal(invalid.succeeded, false)
    assert.equal(invalid.error.kind, "syntax")
    const recovered = await kernel.evaluate("check", parameters("await nodeRepl.write(stable);"))
    assert.equal(recovered.succeeded, true, recovered.error?.message)
    assert.equal(events[0].content.text, "7")
})

test("unobserved helper failures fail the cell while caught rejections remain caught", async () => {
    const { kernel } = harness()
    const unobserved = await kernel.evaluate("unobserved", parameters("nodeRepl.emitImage(new Uint8Array([1, 2]));"))
    assert.equal(unobserved.succeeded, false)
    assert.equal(unobserved.error.kind, "image")
    const caught = await kernel.evaluate("caught", parameters("try { await nodeRepl.emitImage(new Uint8Array([1, 2])); } catch {}"))
    assert.equal(caught.succeeded, true, caught.error?.message)
})

test("request context is immutable and direct process imports are denied", async () => {
    const { kernel, events } = harness()
    const result = await kernel.evaluate("context", parameters(`
if (nodeRepl.requestMeta.request !== 'one' || nodeRepl.env.EXAMPLE !== 'value') throw Error('context');
if (typeof process !== 'undefined' || typeof nodeRepl.rpc !== 'undefined') throw Error('unexpected capability');
try { nodeRepl.env.EXAMPLE = 'changed'; } catch {}
await nodeRepl.write(nodeRepl.env.EXAMPLE);
try { await import('node:process'); throw Error('process import allowed'); } catch (error) {
    if (error.kind !== 'import') throw error;
}
`))
    assert.equal(result.succeeded, true, result.error?.message)
    assert.equal(events[0].content.text, "value")
})

test("the workspace helper is reserved at the top level and can be shadowed inside a block", async () => {
    const { kernel } = harness()
    const first = await kernel.evaluate("original", parameters(`
        const check = await import("node:assert/strict")
        const original = nodeRepl
        check.deepEqual(Object.getOwnPropertyDescriptor(globalThis, "nodeRepl"), {
            value: original, writable: false, configurable: false, enumerable: false,
        })
        check.throws(() => { nodeRepl = null }, { name: "TypeError", message: /read only property/ })
        check.throws(() => { delete globalThis.nodeRepl }, { name: "TypeError", message: /Cannot delete property/ })
    `))
    assert.equal(first.succeeded, true, first.error?.message)
    const shadow = await kernel.evaluate("shadow", parameters("let nodeRepl = 42"))
    assert.equal(shadow.succeeded, false)
    const next = await kernel.evaluate("next", parameters(`
        { let nodeRepl = 42; check.equal(nodeRepl, 42) }
        check.equal(nodeRepl, original)
    `))
    assert.equal(next.succeeded, true, next.error?.message)
    assert.notEqual(createRuntimeContext().context.nodeRepl, createRuntimeContext().context.nodeRepl)
})

test("equal helper context preserves environment identity while metadata stays execution scoped", async () => {
    const { kernel, events } = harness()
    const first = parameters("var savedEnv = nodeRepl.env; var savedMeta = nodeRepl.requestMeta; nodeRepl.write(startupEnv === nodeRepl.env)")
    first.startupSource = "globalThis.startupEnv = nodeRepl.env"
    const initial = await kernel.evaluate("initial", first)
    assert.equal(initial.succeeded, true, initial.error?.message)
    const second = parameters("nodeRepl.write([savedEnv === nodeRepl.env, savedMeta === nodeRepl.requestMeta, Object.isFrozen(nodeRepl.env)])")
    const repeated = await kernel.evaluate("repeated", structuredClone(second))
    assert.equal(repeated.succeeded, true, repeated.error?.message)
    assert.deepEqual(events.map(event => event.content.text), ["true", "[ true, false, true ]"])
})

test("changed helper context invalidates its snapshot without mutating earlier values", async () => {
    const { kernel, events } = harness()
    const first = parameters("var savedEnv = nodeRepl.env; var savedMeta = nodeRepl.requestMeta")
    const initial = await kernel.evaluate("initial", first)
    assert.equal(initial.succeeded, true, initial.error?.message)
    first.context.env.EXAMPLE = "changed outside"
    first.metadata.request = "changed outside"
    const second = parameters(`
let rejectedMutation = false;
try { nodeRepl.env.EXAMPLE = 'untrusted'; } catch { rejectedMutation = true; }
if (savedEnv === nodeRepl.env || savedEnv.EXAMPLE !== 'value' || nodeRepl.env.EXAMPLE !== 'new value'
    || savedMeta.request !== 'one' || nodeRepl.requestMeta.request !== 'two' || !rejectedMutation
    || nodeRepl.cwd !== '/changed/project' || nodeRepl.homeDir !== '/changed/home' || nodeRepl.tmpDir !== '/changed/tmp') {
    throw Error('context snapshot');
}
nodeRepl.write(true);
`)
    second.metadata.request = "two"
    second.context = { cwd: "/changed/project", homeDir: "/changed/home", tmpDir: "/changed/tmp", env: { EXAMPLE: "new value" } }
    const changed = await kernel.evaluate("changed", second)
    assert.equal(changed.succeeded, true, changed.error?.message)
    assert.equal(events[0].content.text, "true")
    const third = parameters("nodeRepl.write(savedEnv === nodeRepl.env)")
    const restored = await kernel.evaluate("restored", third)
    assert.equal(restored.succeeded, true, restored.error?.message)
    assert.equal(events[1].content.text, "false")
})

test("context snapshots compare all values and remain local to a kernel", async () => {
    const first = harness()
    const initialParameters = parameters("var savedEnv = nodeRepl.env")
    initialParameters.context.extra = { nested: true }
    assert.equal((await first.kernel.evaluate("initial", initialParameters)).succeeded, true)
    const changedParameters = parameters("nodeRepl.write(savedEnv === nodeRepl.env)")
    changedParameters.context.extra = { nested: false }
    assert.equal((await first.kernel.evaluate("changed", changedParameters)).succeeded, true)
    assert.equal(first.events[0].content.text, "false")
    const second = harness()
    assert.equal((await second.kernel.evaluate("isolated", parameters("nodeRepl.write(typeof savedEnv)"))).succeeded, true)
    assert.equal(second.events[0].content.text, "undefined")
})

test("images accept bytes, explicitly typed bytes, data URLs, and file URLs", async () => {
    const directory = await mkdtemp(path.join(tmpdir(), "replico-images-"))
    const data = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII="
    try {
        const filename = path.join(directory, "pixel.png")
        await writeFile(filename, Buffer.from(data, "base64"))
        const { kernel, events } = harness(directory)
        const result = await kernel.evaluate("images", parameters(`
const bytes = Buffer.from(${JSON.stringify(data)}, 'base64');
nodeRepl.emitImage(bytes);
await nodeRepl.emitImage({ bytes, mimeType: 'image/png' });
await nodeRepl.emitImage(${JSON.stringify(`data:image/png;base64,${data}`)});
await nodeRepl.emitImage(${JSON.stringify(pathToFileURL(filename).href)});
`, directory))
        assert.equal(result.succeeded, true, result.error?.message)
        assert.equal(events.length, 4)
        for (const event of events) {
            assert.deepEqual(event, { event: "output", executionID: "images", content: { type: "image", data, mimeType: "image/png" } })
        }
    } finally {
        await rm(directory, { recursive: true, force: true })
    }
})

test("invalid or oversized images reject inside JavaScript and remain catchable", async () => {
    const { kernel, events } = harness()
    const result = await kernel.evaluate("invalid-images", parameters(`
const png = new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10]);
let failures = 0;
for (const image of [
    { bytes: png, mimeType: 'image/jpeg' },
    { bytes: png, mimeType: 'image/svg+xml' },
    new Uint8Array(8 * 1024 * 1024 + 1),
]) {
    try { await nodeRepl.emitImage(image); } catch (error) {
        if (error.kind !== 'image') throw error;
        failures += 1;
    }
}
if (failures !== 3) throw Error('image rejection was not catchable');
`))
    assert.equal(result.succeeded, true, result.error?.message)
    assert.equal(events.length, 0)
    const next = await kernel.evaluate("still-alive", parameters("await nodeRepl.write('alive');"))
    assert.equal(next.succeeded, true, next.error?.message)
    assert.equal(events[0].content.text, "alive")
})

test("dynamic builtins retain live exports and static imports keep their own namespace", async () => {
    const cwd = await mkdtemp(path.join(tmpdir(), "module-namespaces-"))
    try {
        await writeFile(path.join(cwd, "local.mjs"), "export * as path from 'node:path'")
        const { kernel, events } = harness(cwd)
        const result = await kernel.evaluate("imports", parameters(`
            const builtin = await import("node:path")
            const alias = await import("path")
            const local = await import("./local.mjs")
            const { syncBuiltinESMExports } = await import("node:module")
            const original = builtin.delimiter
            try {
                builtin.default.delimiter = "updated"
                syncBuiltinESMExports()
                nodeRepl.write([builtin === alias, builtin !== local.path, builtin.delimiter, local.path.delimiter === original])
            } finally {
                builtin.default.delimiter = original
                syncBuiltinESMExports()
            }
        `, cwd))
        assert.equal(result.succeeded, true, result.error?.message)
        assert.equal(events[0].content.text, "[ true, true, 'updated', true ]")
    } finally {
        await rm(cwd, { recursive: true, force: true })
    }
})

test("local module dependencies reload and packages remain cached", async () => {
    const directory = await mkdtemp(path.join(tmpdir(), "replico-modules-"))
    try {
        await writeFile(path.join(directory, "value.mjs"), "export const value = 1;\n")
        await writeFile(path.join(directory, "entry.mjs"), "export { value } from './value.mjs';\n")
        const packageDirectory = path.join(directory, "node_modules", "example")
        await mkdir(packageDirectory, { recursive: true })
        await writeFile(path.join(packageDirectory, "package.json"), JSON.stringify({ name: "example", type: "module", main: "index.js" }))
        await writeFile(path.join(packageDirectory, "index.js"), "export const value = 1;\n")
        const { kernel, events } = harness(directory)
        const source = "const [a, b] = await Promise.all([import('./entry.mjs'), import('./entry.mjs')]); const pkg = await import('example'); await nodeRepl.write([a.value, b.value, pkg.value]);"
        const first = await kernel.evaluate("first", parameters(source, directory))
        assert.equal(first.succeeded, true, first.error?.message)
        await writeFile(path.join(directory, "value.mjs"), "export const value = 2;\n")
        await writeFile(path.join(packageDirectory, "index.js"), "export const value = 2;\n")
        const second = await kernel.evaluate("second", parameters(source, directory))
        assert.equal(second.succeeded, true, second.error?.message)
        const text = events.map(event => event.content.text)
        assert.deepEqual(text, ["[ 1, 1, 1 ]", "[ 2, 2, 1 ]"])
    } finally {
        await rm(directory, { recursive: true, force: true })
    }
})

test("package imports honor ESM conditions and canonical configured roots", async () => {
    const directory = await mkdtemp(path.join(tmpdir(), "replico-roots-"))
    try {
        const cwd = path.join(directory, "project")
        const localModules = path.join(cwd, "node_modules")
        const extraModules = path.join(directory, "extra", "node_modules")
        const externalPackage = path.join(directory, "external")
        const ancestorPackage = path.join(directory, "node_modules", "ancestor")
        await mkdir(localModules, { recursive: true })
        await mkdir(path.join(extraModules, "conditioned"), { recursive: true })
        await mkdir(externalPackage, { recursive: true })
        await mkdir(ancestorPackage, { recursive: true })
        await writeFile(path.join(extraModules, "conditioned", "package.json"), JSON.stringify({ name: "conditioned", type: "module", exports: { import: "./import.mjs" } }))
        await writeFile(path.join(extraModules, "conditioned", "import.mjs"), "export const value = 'import condition';\n")
        for (const packageDirectory of [externalPackage, ancestorPackage]) {
            await writeFile(path.join(packageDirectory, "package.json"), JSON.stringify({ type: "module", main: "index.mjs" }))
            await writeFile(path.join(packageDirectory, "index.mjs"), "export const value = 'outside';\n")
        }
        await symlink(externalPackage, path.join(localModules, "escaped"), "dir")
        const { kernel, events } = harness(cwd)
        const result = await kernel.evaluate("roots", parameters(`
const module = await import('conditioned');
await nodeRepl.write(module.value);
for (const name of ['escaped', 'ancestor']) {
    try { await import(name); throw Error('package root escaped'); } catch (error) {
        if (error.kind !== 'import') throw error;
    }
}
`, cwd, [extraModules]))
        assert.equal(result.succeeded, true, result.error?.message)
        assert.equal(events[0].content.text, "import condition")
    } finally {
        await rm(directory, { recursive: true, force: true })
    }
})

test("missing and deleted optional module roots preserve plain evaluation and package fallback", async () => {
    const directory = await mkdtemp(path.join(tmpdir(), "replico-optional-roots-"))
    try {
        const cwd = path.join(directory, "project")
        const packageDirectory = path.join(cwd, "node_modules", "fallback")
        const missingRoot = path.join(directory, "missing", "node_modules")
        const deletedRoot = path.join(directory, "deleted", "node_modules")
        await mkdir(packageDirectory, { recursive: true })
        await mkdir(deletedRoot, { recursive: true })
        await writeFile(path.join(packageDirectory, "package.json"), JSON.stringify({ type: "module", main: "index.mjs" }))
        await writeFile(path.join(packageDirectory, "index.mjs"), "export const value = 'fallback';\n")
        const { kernel, events } = harness(cwd)
        await rm(deletedRoot, { recursive: true })
        const roots = [missingRoot, deletedRoot]
        const plain = await kernel.evaluate("plain", parameters("await nodeRepl.write(21 * 2);", cwd, roots))
        assert.equal(plain.succeeded, true, plain.error?.message)
        const imported = await kernel.evaluate("fallback", parameters("const module = await import('fallback'); await nodeRepl.write(module.value);", cwd, roots))
        assert.equal(imported.succeeded, true, imported.error?.message)
        assert.deepEqual(events.map(event => event.content.text), ["42", "fallback"])
    } finally {
        await rm(directory, { recursive: true, force: true })
    }
})

test("console and unnamed writes retain whitespace and ordering", async () => {
    const { kernel, events } = harness()
    const interleaved = await kernel.evaluate("interleaved", parameters("console.log('A'); nodeRepl.write('B'); console.log('C')"))
    assert.equal(interleaved.succeeded, true, interleaved.error?.message)
    assert.equal(events.splice(0)[0].content.text, "A\nBC")
    const whitespace = await kernel.evaluate("literal-whitespace", parameters("nodeRepl.write(' A \\n\\t')"))
    assert.equal(whitespace.succeeded, true, whitespace.error?.message)
    assert.equal(events.splice(0)[0].content.text, " A \n\t")
})

test("named text precedes assembled default text and images", async () => {
    const { kernel, events } = harness()
    const data = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII="
    const result = await kernel.evaluate("ordered-output", parameters(`
nodeRepl.write('before')
await nodeRepl.emitImage(Buffer.from('${data}', 'base64'))
nodeRepl.write('named', 'named-item')
nodeRepl.write('after')
`))
    assert.equal(result.succeeded, true, result.error?.message)
    assert.deepEqual(events.map(event => event.content), [
        { type: "text", text: "named", itemID: "named-item" },
        { type: "text", text: "beforeafter" },
        { type: "image", data, mimeType: "image/png" },
    ])
})

test("write rejects empty and nonstring content identifiers but accepts whitespace", async () => {
    const { kernel, events } = harness()
    for (const identifier of ['""', "1", "null", "{}"] ) {
        const result = await kernel.evaluate("invalid-id-" + identifier, parameters(`nodeRepl.write('body', ${identifier})`))
        assert.equal(result.succeeded, false)
        assert.equal(result.error.message, "nodeRepl.write expected a nonempty string content item ID")
    }
    assert.equal(events.length, 0)
    const valid = await kernel.evaluate("whitespace-id", parameters("nodeRepl.write('body', ' ')"))
    assert.equal(valid.succeeded, true, valid.error?.message)
    assert.deepEqual(events[0].content, { type: "text", text: "body", itemID: " " })
})

test("eval and Function reject runtime code generation from strings", async () => {
    const { kernel } = harness()
    for (const source of ["eval(42)", "eval('1 + 1')", "Function('return 1')()"] ) {
        const result = await kernel.evaluate("code-generation-" + source, parameters(source))
        assert.equal(result.succeeded, false)
        assert.equal(result.error.message, "Code generation from strings disallowed for this context")
    }
})

test("trusted startup source runs once per kernel before the first user cell", async () => {
    const source = "globalThis.installations = (globalThis.installations ?? 0) + 1"
    for (let generation = 0; generation < 2; generation++) {
        const { kernel, events } = harness()
        for (let evaluation = 0; evaluation < 2; evaluation++) {
            const result = await kernel.evaluate(`startup-${generation}-${evaluation}`, {
                ...parameters("nodeRepl.write(installations)"), startupSource: source,
            })
            assert.equal(result.succeeded, true, result.error?.message)
        }
        assert.deepEqual(events.map(event => event.content.text), ["1", "1"])
    }
})

test("invalid trusted startup source fails before evaluating user code", async () => {
    const { kernel, events } = harness()
    await assert.rejects(kernel.evaluate("invalid-startup", {
        ...parameters("nodeRepl.write('user code ran')"), startupSource: "throw new Error('startup failed')",
    }), { message: "startup failed" })
    assert.equal(events.length, 0)
})

test("default output buffering rejects content beyond the worker frame budget", async () => {
    const { kernel, events } = harness()
    const result = await kernel.evaluate("buffer-budget", parameters("nodeRepl.write('x'.repeat(64 * 1024 * 1024 + 1))"))
    assert.equal(result.succeeded, false)
    assert.equal(result.error.kind, "output_limit")
    assert.equal(events.length, 0)
})

test("write and console calls return undefined instead of asynchronous handles", async () => {
    const { kernel, events } = harness()
    const result = await kernel.evaluate("void-write", parameters(`
{
const result = nodeRepl.write('x')
nodeRepl.write(JSON.stringify({ type: typeof result, then: typeof result?.then }))
}
`))
    assert.equal(result.succeeded, true, result.error?.message)
    assert.equal(events.splice(0)[0].content.text, 'x{"type":"undefined","then":"undefined"}')
    const logged = await kernel.evaluate("void-log", parameters(`
{
const result = console.log('line')
nodeRepl.write(JSON.stringify({ type: typeof result, then: typeof result?.then }))
}
`))
    assert.equal(logged.succeeded, true, logged.error?.message)
    assert.equal(events.splice(0)[0].content.text, 'line\n{"type":"undefined","then":"undefined"}')
})

test("invalid write identifiers throw synchronously and remain catchable without await", async () => {
    const { kernel, events } = harness()
    const result = await kernel.evaluate("synchronous-write-error", parameters(`
let caughtInvalidID = false
try {
    nodeRepl.write('x', '')
} catch {
    caughtInvalidID = true
}
nodeRepl.write(JSON.stringify({ caughtInvalidID }))
`))
    assert.equal(result.succeeded, true, result.error?.message)
    assert.equal(events[0].content.text, '{"caughtInvalidID":true}')
})

test("write and console formatting failures throw in their calling expression", async () => {
    const { kernel, events } = harness()
    const result = await kernel.evaluate("synchronous-format-error", parameters(`
const value = {
    [Symbol.for('nodejs.util.inspect.custom')]() {
        throw new Error('format failure')
    }
}
const caught = []
try {
    nodeRepl.write(value)
} catch {
    caught.push('write')
}
try {
    console.log(value)
} catch {
    caught.push('log')
}
nodeRepl.write(JSON.stringify(caught))
`))
    assert.equal(result.succeeded, true, result.error?.message)
    assert.equal(events[0].content.text, '["write","log"]')
})

test("var is hoisted out of a block while a loop lexical stays local", async () => {
    const { kernel, events } = harness()
    const first = await kernel.evaluate("transient-first", parameters(`
{
    var hidden = 1
}
for (let transient of [2]) {
}
globalThis.savedValue = 3
`))
    assert.equal(first.succeeded, true, first.error?.message)
    const next = await kernel.evaluate("transient-next", parameters("nodeRepl.write(JSON.stringify([typeof hidden, typeof transient, savedValue]))"))
    assert.equal(next.succeeded, true, next.error?.message)
    assert.equal(events.splice(0)[0].content.text, '["number","undefined",3]')
    const declared = await kernel.evaluate("persistent-loop", parameters("for (var retained of [4]) {}"))
    assert.equal(declared.succeeded, true, declared.error?.message)
    const carried = await kernel.evaluate("persistent-next", parameters("nodeRepl.write(retained)"))
    assert.equal(carried.succeeded, true, carried.error?.message)
    assert.equal(events[0].content.text, "4")
})

test("function expressions keep their original source across declaration-free cells", async () => {
    const { kernel, events } = harness()
    const source = `function count(value) {
    return value === 0 ? 0 : count(value - 1) + 1
}`
    const installed = await kernel.evaluate("global-function", parameters("globalThis.savedFunction = " + source))
    assert.equal(installed.succeeded, true, installed.error?.message)
    const result = await kernel.evaluate("global-function-read", parameters("nodeRepl.write(JSON.stringify([savedFunction(3), savedFunction.toString()]))"))
    assert.equal(result.succeeded, true, result.error?.message)
    assert.equal(events[0].content.text, JSON.stringify([3, source]))
})

test("maximum-size source executes repeatedly with current request metadata", async () => {
    const { kernel, events } = harness()
    const body = "nodeRepl.write(nodeRepl.requestMeta.request)"
    const source = "/*" + "x".repeat(1024 * 1024 - Buffer.byteLength(body) - 5) + "*/\n" + body
    assert.equal(Buffer.byteLength(source), 1024 * 1024)
    for (const request of ["first", "second", "third"]) {
        const result = await kernel.evaluate(`large-source-${request}`, { ...parameters(source), metadata: { request } })
        assert.equal(result.succeeded, true, result.error?.message)
    }
    assert.deepEqual(events.map(event => event.content.text), ["first", "second", "third"])
})

test("retained closures identify their creating cell when a large program is repeated", async () => {
    const { kernel, events } = harness()
    const setup = await kernel.evaluate("setup", parameters(`
        globalThis.locations = []
        Error.prepareStackTrace = (_, [frame]) => ({ url: frame.getScriptNameOrSourceURL(), hash: frame.getScriptHash() })
    `))
    assert.equal(setup.succeeded, true, setup.error?.message)
    const code = `locations.push(() => Error().stack)
        nodeRepl.write(JSON.stringify(locations.at(-1)()))
        /*${"x".repeat(64 * 1024)}*/`
    for (const id of ["first", "second"]) {
        const result = await kernel.evaluate(id, parameters(code))
        assert.equal(result.succeeded, true, result.error?.message)
    }
    const read = await kernel.evaluate("read", parameters("nodeRepl.write(JSON.stringify(locations.map(locate => locate())))"))
    assert.equal(read.succeeded, true, read.error?.message)
    const [first, second, retained] = events.map(event => JSON.parse(event.content.text))
    assert.notEqual(first.url, second.url)
    assert.notEqual(first.hash, second.hash)
    assert.deepEqual(retained, [first, second])
})

test("large and small calls give retained promises the same output lifetime", async () => {
    const observations = []
    for (const payload of ["[1]", JSON.stringify(Array(10_000).fill(1))]) {
        const { kernel, events } = harness()
        const setup = await kernel.evaluate("register", parameters(`
let finished
function count(values) {
    finished = [1, 2, 3, 4, 5].reduce(
        (prior, number) => prior.then(() => nodeRepl.write(values[0] * number)),
        Promise.resolve()
    ).catch(error => error.kind)
}
`))
        assert.equal(setup.succeeded, true, setup.error?.message)
        const counted = await kernel.evaluate("count", parameters(`count(${payload})`))
        assert.equal(counted.succeeded, true, counted.error?.message)
        const acknowledged = await kernel.evaluate("acknowledge", parameters("nodeRepl.write(await finished)"))
        assert.equal(acknowledged.succeeded, true, acknowledged.error?.message)
        observations.push(events.map(event => event.content.text))
    }
    assert.ok(observations[0][0].startsWith("1"))
    assert.deepEqual(observations[1], observations[0])
})

test("large calls describe a thrown workspace error in the same realm as small calls", async () => {
    const messages = []
    for (const payload of ["[1]", JSON.stringify(Array(10_000).fill(1))]) {
        const { kernel, events } = harness()
        const setup = await kernel.evaluate("register", parameters(`
let reads = 0
const fault = Object.defineProperty(new Error(), "message", {
    get() {
        return String(++reads)
    }
})
const report = () => {
    throw fault
}
`))
        assert.equal(setup.succeeded, true, setup.error?.message)
        const failed = await kernel.evaluate("report", parameters(`report(${payload})`))
        assert.equal(failed.succeeded, false)
        const inspect = await kernel.evaluate("reads", parameters("nodeRepl.write(reads)"))
        assert.equal(inspect.succeeded, true, inspect.error?.message)
        messages.push([failed.error.message, events[0].content.text])
    }
    assert.deepEqual(messages[1], messages[0])
})

test("repeated import expressions reload their local dependency graph", async () => {
    const directory = await mkdtemp(path.join(tmpdir(), "replico-repeated-import-"))
    try {
        await writeFile(path.join(directory, "entry.mjs"), "export { value } from './leaf.mjs'\n")
        await writeFile(path.join(directory, "leaf.mjs"), "export const value = 1\n")
        const { kernel, events } = harness(directory)
        const source = "nodeRepl.write((await import('./entry.mjs')).value)"
        const first = await kernel.evaluate("repeated-import-first", parameters(source, directory))
        assert.equal(first.succeeded, true, first.error?.message)
        await writeFile(path.join(directory, "leaf.mjs"), "export const value = 2\n")
        const second = await kernel.evaluate("repeated-import-second", parameters(source, directory))
        assert.equal(second.succeeded, true, second.error?.message)
        await writeFile(path.join(directory, "leaf.mjs"), "export const value = 3\n")
        const third = await kernel.evaluate("repeated-import-third", parameters(source, directory))
        assert.equal(third.succeeded, true, third.error?.message)
        assert.deepEqual(events.map(event => event.content.text), ["1", "2", "3"])
    } finally {
        await rm(directory, { recursive: true, force: true })
    }
})

test("new declarations remain visible when earlier expression source repeats", async () => {
    const { kernel, events } = harness()
    const source = "nodeRepl.write(typeof retained)"
    const first = await kernel.evaluate("before-declaration", parameters(source))
    assert.equal(first.succeeded, true, first.error?.message)
    const declared = await kernel.evaluate("declare-retained", parameters("let retained = 7"))
    assert.equal(declared.succeeded, true, declared.error?.message)
    const next = await kernel.evaluate("after-declaration", parameters(source))
    assert.equal(next.succeeded, true, next.error?.message)
    assert.deepEqual(events.map(event => event.content.text), ["undefined", "number"])
})

test("repeated stateful cells share live lexical bindings and object identities", async () => {
    const { kernel, events } = harness()
    const seed = await kernel.evaluate("stateful-seed", parameters("let value = 1; const original = () => value; let object = { count: 0 }; let originalObject = object"))
    assert.equal(seed.succeeded, true, seed.error?.message)
    const source = "value += 1; object.count += 1; nodeRepl.write(JSON.stringify([value, original(), object.count, object === originalObject]))"
    for (let index = 0; index < 3; index++) {
        const result = await kernel.evaluate(`stateful-repeat-${index}`, parameters(source))
        assert.equal(result.succeeded, true, result.error?.message)
    }
    assert.deepEqual(events.map(event => event.content.text), ["[2,2,1,true]", "[3,3,2,true]", "[4,4,3,true]"])
})

test("repeated failing declarations retain bindings introduced by the preceding execution", async () => {
    const { kernel, events } = harness()
    const source = "let retained = nodeRepl.requestMeta.fail ? missingInitializer() : 7"
    const first = await kernel.evaluate("new-binding-first", parameters(source))
    assert.equal(first.succeeded, true, first.error?.message)
    for (let index = 0; index < 3; index++) {
        const failed = await kernel.evaluate(`new-binding-failed-${index}`, { ...parameters(source), metadata: { fail: true } })
        assert.equal(failed.succeeded, false)
    }
    const recovered = await kernel.evaluate("new-binding-recovered", parameters("nodeRepl.write(retained)"))
    assert.equal(recovered.succeeded, true, recovered.error?.message)
    assert.equal(events[0].content.text, "7")
})

test("repeated partial failures select initialized declarations and retain unreached values", async () => {
    const { kernel, events } = harness()
    const seed = await kernel.evaluate("partial-repeat-seed", parameters("let value = 1; let completed = 0; let unreached = 99"))
    assert.equal(seed.succeeded, true, seed.error?.message)
    const source = `
let completed = nodeRepl.requestMeta.iteration
value += 1
if (nodeRepl.requestMeta.fail) throw Error('stop')
let unreached = completed * 10
`
    for (let iteration = 2; iteration <= 4; iteration++) {
        const result = await kernel.evaluate(`partial-repeat-${iteration}`, {
            ...parameters(source), metadata: { iteration, fail: iteration > 2 },
        })
        assert.equal(result.succeeded, iteration === 2)
    }
    const recovered = await kernel.evaluate("partial-repeat-recovered", parameters("nodeRepl.write(JSON.stringify([value, completed, unreached]))"))
    assert.equal(recovered.succeeded, true, recovered.error?.message)
    assert.equal(events[0].content.text, "[4,4,20]")
})
