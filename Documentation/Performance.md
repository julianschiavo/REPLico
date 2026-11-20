# Performance

Two macOS 27.2 arm64 release builds on an Apple M5 Max ran the same examples with Node 26.13.1 on November 19, 2026. The baseline ships Node and the worker beside the executable. The new build embeds both. Times are milliseconds, shown as median / p95.

## CLI and MCP startup

The driver alternated 32 pairs of installations. Each pair used a fresh user cache, then launched a second process with the populated cache. Each live MCP session also made 32 calls to the Swift multiplication tool. [Packaging benchmark](../Benchmarks/packaging.py)

| math-complex workload | Separate bundles | Embedded |
| --- | ---: | ---: |
| Calculator command | 8.004 / 8.526 | 8.454 / 9.793 |
| Calculator command, 512 launches per build | 9.035 / 11.409 | 9.687 / 12.880 |
| MCP initialize | 11.308 / 12.210 | 10.925 / 11.551 |
| List tools | 0.196 / 0.246 | 0.194 / 0.234 |
| Launch through first result, empty cache | 51.972 / 64.481 | 1,040.256 / 1,192.579 |
| Launch through first result, populated cache | 52.334 / 55.205 | 52.501 / 63.261 |
| Launch through first result, 192 pairs sharing a populated cache | 51.417 / 56.434 | 52.220 / 57.584 |
| Swift tool round trip | 0.224 / 0.413 | 0.220 / 0.424 |

The larger executable added a small, reproducible cost to launching the calculator and to starting a fresh MCP process with a populated cache. The median Swift tool call held steady. A profile of six fresh installations found that starting the newly written Node executable accounted for most of the first call. Apps using the same Node build share that cache.

| Empty cache profile | Median (ms) |
| --- | ---: |
| Write Node and its notices | 171.57 |
| First execution of Node | 851.46 |
| Second execution of the same file | 17.86 |

## Persistent sessions

Both builds agreed on all 38 compatibility cases and returned the expected results for all 320 sequence cells. Single calls have 180 samples per build. Each 64 cell sequence has 30 replays. The last column records the earlier November 17 comparison against the external reference. [Fixtures](../Benchmarks/Fixtures)

| Workload | Separate bundles | Embedded | Earlier speedup vs. reference |
| --- | ---: | ---: | ---: |
| Minimal cell | 0.131 / 0.234 | 0.132 / 0.255 | 1.20× / 1.50× |
| One write | 0.143 / 0.250 | 0.146 / 0.276 | 1.18× / 1.33× |
| 64 KiB input | 0.277 / 0.483 | 0.272 / 0.445 | 2.22× / 1.99× |
| 1 MiB input | 1.747 / 2.678 | 1.748 / 2.587 | 4.30× / 4.02× |
| 1 MiB output | 1.420 / 1.764 | 1.431 / 1.797 | 1.65× / 1.93× |
| 1,000 writes | 0.249 / 0.434 | 0.255 / 0.419 | 1.50× / 1.52× |
| 1,000 bindings | 0.128 / 0.245 | 0.128 / 0.211 | 8.64× / 5.72× |
| 5,000 bindings | 0.130 / 0.242 | 0.130 / 0.253 | 36.89× / 28.46× |
| Arithmetic ledger | 11.826 / 13.127 | 12.114 / 12.855 | 1.67× / 1.16× |
| Text catalog | 13.131 / 14.541 | 13.288 / 16.324 | 1.56× / 1.38× |
| Tree traversal | 15.875 / 21.975 | 15.718 / 22.775 | 1.50× / 1.08× |
| Unicode and caught errors | 12.923 / 19.480 | 13.294 / 18.143 | 1.55× / 1.37× |
| Media and state | 21.315 / 29.895 | 21.445 / 32.199 | 1.59× / 1.40× |

## Reproduce the comparison

Build both example packages in release mode. Supply the old and new `math-complex` executables to the packaging driver and their `math` executables to the session driver. The reports record samples and executable hashes.

```sh
python3 Benchmarks/packaging.py --before "$BEFORE/math-complex" --after "$AFTER/math-complex" \
  --rounds 32 --calls 32 --output .runtime/performance/packaging.json
python3 Benchmarks/packaging.py --before "$BEFORE/math-complex" --after "$AFTER/math-complex" \
  --cli-only --rounds 256 --output .runtime/performance/cli.json
Benchmarks/compare.py --agent "$AFTER/math" --reference "$BEFORE/math" \
  --node "$NODE" --reference-node "$NODE" --rounds 6 --output .runtime/performance/sessions.json
```
