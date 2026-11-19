# Performance

The November 19, 2026 cleanup check compares two release builds of the same host on macOS 27.2 arm64 with Node 26.13.1. The second pass swapped their order. Both builds matched on all 38 compatibility cases and returned the expected output from all 320 sequence cells. [Fixtures](../Benchmarks/Fixtures)

All five sequence medians stayed within 1% of the previous build. Restoring the previous output path removed the slowdown for 1,000 writes. The largest remaining increase was the 1 MiB input p95 at 4.1%. Its median fell slightly. Running the frozen build against itself produced a 6.8% p95 difference on the same row.

Times are milliseconds, shown as median / p95. Startup has six samples per build, single calls have 180, and each 64 cell sequence has 30 replays. Startup reports the median only. The last column comes from a separate November 17 comparison of an earlier build against the external reference. That build matched 19 of the reference’s 38 behavior cases. [JavaScript behavior](Compatibility.md)

| Workload | Before cleanup | After cleanup | Earlier speedup vs. reference |
| --- | ---: | ---: | ---: |
| Initialize | 7.740 | 7.554 | 18.19× |
| Launch through first result | 43.890 | 44.700 | 4.49× |
| Minimal cell | 0.121 / 0.191 | 0.123 / 0.195 | 1.20× / 1.50× |
| One write | 0.123 / 0.199 | 0.123 / 0.203 | 1.18× / 1.33× |
| 64 KiB input | 0.226 / 0.336 | 0.229 / 0.323 | 2.22× / 1.99× |
| 1 MiB input | 1.492 / 1.746 | 1.486 / 1.818 | 4.30× / 4.02× |
| 1 MiB output | 1.242 / 1.600 | 1.235 / 1.585 | 1.65× / 1.93× |
| 1,000 writes | 0.221 / 0.327 | 0.216 / 0.320 | 1.50× / 1.52× |
| 1,000 bindings | 0.112 / 0.178 | 0.114 / 0.176 | 8.64× / 5.72× |
| 5,000 bindings | 0.114 / 0.178 | 0.114 / 0.185 | 36.89× / 28.46× |
| Arithmetic ledger | 9.908 / 12.492 | 9.907 / 12.245 | 1.67× / 1.16× |
| Text catalog | 11.436 / 12.768 | 11.337 / 12.984 | 1.56× / 1.38× |
| Tree traversal | 12.900 / 13.884 | 13.026 / 13.980 | 1.50× / 1.08× |
| Unicode and caught errors | 11.090 / 11.706 | 11.007 / 11.780 | 1.55× / 1.37× |
| Media and state | 17.805 / 18.220 | 17.728 / 18.722 | 1.59× / 1.40× |

## Reproduce the comparison

Build both hosts in release mode and configure them to use the supplied Node executable. The driver checks cell results, alternates the hosts, and writes raw samples and executable hashes. Swap the hosts for a second pass.

```sh
Benchmarks/compare.py --agent "$AFTER" --reference "$BEFORE" \
  --node "$NODE" --reference-node "$NODE" --output .runtime/performance/comparison.json
```
