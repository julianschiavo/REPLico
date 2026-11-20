# Embedding REPLico

| Module | Use it for | Entry point |
| --- | --- | --- |
| ReplicoKit | Building an MCP server with typed Swift tools callable from JavaScript | `ReplicoApplication` |
| ReplicoCore | Running JavaScript directly in a persistent Node subprocess | `REPLSession` |
| ReplicoMCP | Serving a custom tool registry or an MCP SDK transport | `ReplicoServer` |

Kit composes the other two modules. The runtime owns the worker, imports, deadlines and Swift services. The MCP adapter owns requests and connection lifetime. Their internal wire helpers live in `ReplicoOptimizations`. [Implementation notes](Optimizations.md)

## Hosting an application

MCP clients see the host executable’s name and its bundle version when available. For a command line tool, set the name and version you ship in `ApplicationConfiguration(serverInfo: .init(name: "text-server", version: "1.2.3", title: "Text Server"))`.

Declare each Swift tool’s arguments with `@ToolArguments` and describe its properties with `@Argument`. The macro supports strings, Booleans, integer and floating point types, arrays and optionals. Use `NoArguments` for an empty object or implement `ToolArgumentsProtocol` for a custom schema. A `ToolGroup` installs a JavaScript namespace each time a worker starts. [Complete application](../README.md#create-a-server)

The `ReplicoKit` product links a compressed copy of Node and its notices into the host executable. The JavaScript worker is embedded in `ReplicoCore`. REPLico installs these files in the user's private cache on demand and runs Node as a subprocess. Applications with their own entry point can call `try await serve()` when they enter MCP mode. [Example](../Examples/MathComplex)

On Linux the executable uses the app's usual Swift runtime linkage. [Deploying Swift executables on Linux](https://docs.swift.org/latest/documentation/swiftlinux/building/)

To supply your own Node executable, depend on `ReplicoKitExternalNode`, import `ReplicoKit` and return `ApplicationConfiguration(nodeRuntime: .external(executableURL))` from the application.

## Running JavaScript directly

```swift
import ReplicoCore
import Foundation

let session = try REPLSession(configuration: REPLConfiguration(
    nodeExecutable: URL(filePath: "/absolute/path/to/node")
))
do {
    let result = try await session.evaluate(EvaluationRequest(code: "nodeRepl.write(6 * 7)"))
    print(result.content)
    await session.shutDown()
} catch {
    await session.shutDown()
    throw error
}
```

A session evaluates one cell at a time. JavaScript errors set `didFail` and preserve earlier output. Cancelling a queued request removes that request. Cancelling a running cell or exceeding its deadline stops the worker and cancels its host services. The next evaluation starts a fresh worker. `reset()` also clears queued evaluations and preserves registered module directories.

Pass `services:` when creating the session to expose Swift capabilities through `nodeRepl.rpc`. A `REPLService` receives the execution ID, metadata and JSON payload. Its `ServiceResponse` returns a value and can contribute text or images. Services can run concurrently and must finish their cleanup on cancellation. Calling `evaluate`, `reset` or `shutDown` on the originating session from its service handler would deadlock.

## Providing an MCP transport

```swift
let server = try ReplicoServer(session: session)
try await server.run(over: transport)
```

The default tools are `js`, `js_reset` and `js_add_node_module_dir`. Pass `tools:` to replace the registry. Each `ReplicoMCP.Tool` supplies an SDK tool definition, decodable arguments and an asynchronous implementation. EOF cancels admitted calls and closes the session.

The adapter translates host sandbox metadata into a `LaunchPolicy` when dispatching a tool call. The runtime applies the policy at the front of the evaluation queue. Changing the launcher retires the worker. Once sandboxing is required, a missing launcher rejects execution, including after a reset.
