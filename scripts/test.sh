#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

python3 -m unittest discover -s Tests/Maintenance
swift_test=(swift test --disable-automatic-resolution)
if [[ ${GITHUB_ACTIONS:-} == true ]]; then
    if [[ ${RUNNER_OS:-} == Linux ]]; then
        swift_test=(stdbuf -o0 -e0 "${swift_test[@]}")
    fi
    NSUnbufferedIO=YES SWIFTNIO_STRICT=1 "${swift_test[@]}" 2>&1 |
        xcbeautify --renderer github-actions --preserve-unbeautified
else
    SWIFTNIO_STRICT=1 "${swift_test[@]}"
fi
exec .runtime/ReplicoRuntime.artifactbundle/bin/node \
    --experimental-vm-modules --experimental-import-meta-resolve --test Tests/NodeWorker/*.test.mjs
