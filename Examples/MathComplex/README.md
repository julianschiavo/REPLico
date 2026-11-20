# Math with an existing entry point

This standalone package uses Swift Argument Parser. Its command line and MCP tools share a `Calculator`. The `--mcp` flag calls `try await serve()` to start the server.

Run the calculator from this directory. SwiftPM downloads a compatible REPLico release and its Node runtime.

```sh
swift run math-complex add 2 3
# 5
```

To distribute the calculator, run `swift build -c release --product math-complex` and copy the `math-complex` executable from the directory printed by `swift build -c release --show-bin-path`. An MCP client can launch that copy with `--mcp`.

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
