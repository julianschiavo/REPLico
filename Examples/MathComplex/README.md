# Math with an existing entry point

This calculator uses Swift Argument Parser. Its command line and MCP tools share a `Calculator`. The `--mcp` flag calls `try await serve()` to start the server.

```sh
swift build --product math-complex
"$(swift build --show-bin-path)/math-complex" add 2 3
# 5
```

To use the calculator from an MCP client, point the client at the built executable and pass `--mcp`.

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
