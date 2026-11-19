import assert from "node:assert/strict"
import path from "node:path"
import test from "node:test"
import { pathToFileURL } from "node:url"
import { Kernel } from "../../Sources/ReplicoCore/Resources/NodeWorker.bundle/kernel.mjs"
import { ServiceBridge } from "../../Sources/ReplicoCore/Resources/NodeWorker.bundle/services.mjs"

test("cell identifier prefixes preserve native URL conversion for every directory shape", async () => {
    const directories = ["/", "/plain/project", "/space in/path", "/Unicode/é🙂漢字", "/reserved/#?%/path", "/trailing/", "/duplicate//nested/../path"]
    const identifier = "01234567-89ab-cdef-0123-456789abcdef"
    for (const cwd of directories) {
        const prefix = pathToFileURL(path.join(cwd, "__replico_")).href
        assert.equal(prefix + identifier + ".mjs", pathToFileURL(path.join(cwd, `__replico_${identifier}.mjs`)).href)
        const events = []
        const kernel = new Kernel({
            cwd,
            services: new ServiceBridge(async () => undefined),
            send: async event => {
                events.push(event)
            },
        })
        const outcome = await kernel.evaluate("identifier", {
            code: "nodeRepl.write(new Error('where').stack)", metadata: {}, serviceNames: [], moduleDirectories: [],
            context: { cwd, homeDir: "/home/example", tmpDir: "/tmp", env: {} },
        })
        assert.equal(outcome.succeeded, true, outcome.error?.message)
        assert.equal(events[0].content.text.includes(prefix), true, cwd)
    }
})
