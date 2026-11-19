# Math

This example registers four Swift tools under the JavaScript namespace `math`. The default `ReplicoApplication` entry point serves them over stdio.

```sh
swift build --product math
```

Set your MCP client's command to the `math` executable in the directory printed by `swift build --show-bin-path`. Ask the client to multiply six by seven. It can call the `js` tool with this code.

```javascript
nodeRepl.write(await math.mult({a: 6, b: 7}))
// 42
```

The other operations are `add`, `sub` and `div`. Division by zero rejects the promise with the Swift error message. [Application with its own entry point](../MathComplex)
