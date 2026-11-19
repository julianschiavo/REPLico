#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

python3 -m unittest discover -s Tests/Maintenance
# SwiftPM matches a workspace package to its Git URL by directory name.
package_root="$PWD"
if [[ ${PWD##*/} != REPLico ]]; then
    mkdir -p .build
    ln -sfn .. .build/REPLico
    package_root="$PWD/.build/REPLico"
fi
swift_test=(swift test --multiroot-data-file "$package_root/Tests/Packages.xcworkspace"
    --scratch-path "$PWD/.build" --disable-automatic-resolution)
if [[ ${GITHUB_ACTIONS:-} == true ]]; then
    if [[ ${RUNNER_OS:-} == Linux ]]; then
        swift_test=(stdbuf -o0 -e0 "${swift_test[@]}")
        if [[ -n ${SWIFT_TEST_IMAGE:-} ]]; then
            swift_test=(docker run --rm --init --user "$(id -u):$(id -g)"
                --volume "$PWD:$PWD" --workdir "$PWD" --env HOME=/tmp
                --env NSUnbufferedIO --env SWIFTNIO_STRICT "$SWIFT_TEST_IMAGE" "${swift_test[@]}")
        fi
    fi
    NSUnbufferedIO=YES SWIFTNIO_STRICT=1 "${swift_test[@]}" 2>&1 |
        xcbeautify --renderer github-actions --preserve-unbeautified
else
    SWIFTNIO_STRICT=1 "${swift_test[@]}"
fi
exec .runtime/ReplicoRuntime.artifactbundle/bin/node \
    --experimental-vm-modules --experimental-import-meta-resolve --test Tests/NodeWorker/*.test.mjs
