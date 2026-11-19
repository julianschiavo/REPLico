# Math

This standalone package registers four Swift tools under the JavaScript namespace `math`. The default `ReplicoApplication` entry point serves them over stdio.

Build the example from this directory. SwiftPM downloads a compatible REPLico release and its Node runtime.

```sh
swift build --product math
```

Set your MCP client's command to the `math` executable in the directory printed by `swift build --show-bin-path`. Ask it to multiply six by seven. The client can call `js` with this code.

```javascript
nodeRepl.write(await math.mult({a: 6, b: 7}))
// 42
```

The other operations are `add`, `sub` and `div`. Division by zero rejects the promise with the Swift error message. [Application with its own entry point](../MathComplex)
