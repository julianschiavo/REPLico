# Stateful benchmark fixtures

Each suite runs 64 cells in a fresh session. The cells retain bindings between calls and check the exact output after every operation. Image checks cover ordering, MIME type, byte count and SHA256 digest. [Cells and expected results](../sequences.json)

| Suite | Operations |
| --- | --- |
| Arithmetic ledger | Adjust balances, await batches and check totals |
| Text catalog | Select records, update retained references and summarize Unicode text |
| Tree traversal | Navigate a hierarchy, batch lookups and compare snapshots |
| Unicode and caught errors | Transform buffers, combine writes and recover from asynchronous errors |
| Media and state | Update shared state and emit six JPEGs from bytes, file URLs and data URLs |

The fixtures borrow call shapes from past sessions. The programs, records, hierarchy and images are synthetic. Timing covers local JavaScript execution and MCP round trips. Each replay starts in the repository root so the programs can find their fixtures.

The checked in JPEGs are ready to use. Image dimensions, encoding settings and digests are in the [media manifest](Media/manifest.json).
