#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

python3 -m unittest discover -s Tests/Maintenance
export NSUnbufferedIO=YES SWIFTNIO_STRICT=1
swift=(swift)
if [[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_OS:-} == Linux ]]; then
    swift=(stdbuf -o0 -e0 swift)
    if [[ -n ${SWIFT_TEST_IMAGE:-} ]]; then
        swift=(docker run --rm --init --user "$(id -u):$(id -g)"
            --volume "$PWD:$PWD" --workdir "$PWD" --env HOME=/tmp
            --env NSUnbufferedIO --env SWIFTNIO_STRICT "$SWIFT_TEST_IMAGE" "${swift[@]}")
    fi
fi

run_swift() {
    if [[ ${GITHUB_ACTIONS:-} == true ]]; then
        "${swift[@]}" "$@" 2>&1 | xcbeautify --renderer github-actions --preserve-unbeautified
    else
        "${swift[@]}" "$@"
    fi
}

run_swift test --disable-automatic-resolution

# Exercise each standalone app against the checkout that will become the next release.
build_example() {
    local example="Examples/$1" fixture=".build/examples/$1" product="$2"
    shift 2
    mkdir -p "$fixture"
    ln -sfn "$PWD/$example/Sources" "$fixture/Sources"
    cp Package.resolved "$fixture/Package.resolved"
    sed -E 's@url: "https://github\.com/julianschiavo/REPLico\.git", from: "[^"]+"@name: "replico", path: "../../.."@' \
        "$example/Package.swift" > "$fixture/Package.swift"
    run_swift build --package-path "$fixture" --scratch-path "$PWD/.build" --product "$product" "$@"
}
# Math only depends on ReplicoKit. MathComplex also resolves Swift Argument Parser.
build_example Math math --disable-automatic-resolution
build_example MathComplex math-complex

exec .runtime/ReplicoRuntime.artifactbundle/bin/node \
    --experimental-vm-modules --experimental-import-meta-resolve --test Tests/NodeWorker/*.test.mjs
