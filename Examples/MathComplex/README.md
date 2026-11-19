# Math with an existing entry point

This standalone package uses Swift Argument Parser. Its command line and MCP tools share a `Calculator`. The `--mcp` flag calls `try await serve()` to start the server.

Run the calculator from this directory. SwiftPM downloads a compatible REPLico release and its Node runtime.

```sh
swift run math-complex add 2 3
# 5
```

To use the calculator from an MCP client, point it at `math-complex` in the directory printed by `swift build --show-bin-path` and pass `--mcp`.

```json
{
  "mcpServers": {
    "math": {
      "command": "/absolute/path/to/math-complex",
      "args": ["--mcp"]
    }
  }
}
```

The client can now call `math.add`, `math.sub`, `math.mult` and `math.div` from JavaScript. [Math example](../Math)
