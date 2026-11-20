import assert from "node:assert/strict"
import { execFileSync, spawn } from "node:child_process"
import { once } from "node:events"
import { copyFileSync, existsSync, mkdirSync, mkdtempDisposableSync } from "node:fs"
import { tmpdir } from "node:os"
import path from "node:path"
import { createInterface } from "node:readline"

using installation = mkdtempDisposableSync(path.join(tmpdir(), "replico-install-"))
const cwd = installation.path
const home = path.join(cwd, "home")
mkdirSync(home)
const env = { ...process.env, HOME: home, CFFIXED_USER_HOME: home, XDG_CACHE_HOME: path.join(home, ".cache"), PATH: "" }
const cache = path.join(process.platform === "darwin" ? path.join(home, "Library", "Caches") : env.XDG_CACHE_HOME, "REPLico")
const apps = ["math", "math-complex"]
for (const name of apps) {
    copyFileSync(path.join(process.argv[2], name), path.join(cwd, name))
}

const cli = execFileSync(path.join(cwd, "math-complex"), ["mult", "6", "7"], { cwd, env, encoding: "utf8" })
assert.equal(cli.trim(), "42")
assert.equal(existsSync(cache), false, "A calculator command installed the MCP runtime")

for (const name of apps) {
    const child = spawn(path.join(cwd, name), name === "math" ? [] : ["--mcp"], { cwd, env, stdio: ["pipe", "pipe", "inherit"] })
    const closed = once(child, "close")
    const replies = createInterface({ input: child.stdout })[Symbol.asyncIterator]()
    let id = 0
    function send(message) {
        child.stdin.write(JSON.stringify({ jsonrpc: "2.0", ...message }) + "\n")
    }
    async function request(method, params) {
        send({ id: ++id, method, params })
        const { value } = await replies.next()
        assert.ok(value, `${name} exited before replying to ${method}`)
        const response = JSON.parse(value)
        assert.equal(response.id, id)
        assert.equal(response.error, undefined)
        return response.result
    }
    try {
        const info = await request("initialize", {
            protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "installation-test", version: "1" },
        })
        assert.equal(info.serverInfo.name, name)
        send({ method: "notifications/initialized" })
        const { tools } = await request("tools/list", {})
        assert.ok(tools.some(tool => tool.name === "js"))
        if (name === "math") assert.equal(existsSync(cache), false, "MCP discovery installed the runtime")
        const result = await request("tools/call", { name: "js", arguments: { code: "nodeRepl.write(await math.mult({a: 6, b: 7}))" } })
        assert.deepEqual(result.content, [{ type: "text", text: "42" }])
        assert.ok(existsSync(cache), "The runtime did not use the isolated user cache")
    } finally {
        child.stdin.end()
        assert.deepEqual(await closed, [0, null])
    }
}
console.log("Standalone math and math-complex passed.")
