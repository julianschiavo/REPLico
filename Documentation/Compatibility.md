# JavaScript compatibility

REPLico provides a persistent JavaScript workspace with the following execution behavior.

- Cells run in one V8 REPL context with top-level await. Closures see later assignments and redeclarations of the same binding. Objects keep their identity.
- A later cell can redeclare a `let` with `let` or a `const` with `const`. Assigning to a constant throws. A throw preserves side effects and completed initializers. An uninitialized lexical can be initialized by a later redeclaration.
- Use dynamic imports. Static imports in submitted cells and direct `process`/`node:process` imports are rejected. Local `.js`/`.mjs` graphs reload; packages remain cached and resolve through configured dependency roots.
- `nodeRepl.write(value, itemID?)` and captured console calls produce text. Expression results are not implicitly displayed.
- `emitImage` accepts bytes, data/file URLs, or `{ bytes, mimeType }`. Reads occur in the worker. PNG, JPEG, WebP and explicitly typed GIF content are validated; images are limited to 8 MiB and total output to the configured budget.
- `cwd`, `homeDir`, `tmpDir`, explicitly exposed `env`, and immutable active-call `requestMeta` provide context. The frozen environment retains identity across cells; request metadata is fresh for each call. `rpc` exists only with registered services. Tracked helpers finish before a cell returns; late output and service replies cannot attach to later executions.

Cells use script syntax. Module-only forms such as `export` and `import.meta` belong in an imported file.

Stack traces include the cell URL and guest source positions. Parent frames can identify either Node’s inspector or `vm.Script` for large synchronous cells.
