#!/usr/bin/env python3
"""Compare relocated math-complex releases with alternating process order.

Cold means an empty application cache. Operating system file caches stay in place.
Each warm launch reuses the files created by the preceding cold sample.
"""

import argparse
from contextlib import closing, contextmanager, nullcontext
import os
from pathlib import Path
import platform
import resource
import shutil
import subprocess
import tempfile
import time

from compare import Client, build_manifest, save, summarize


@contextmanager
def profile(samples, name):
    """Measure OS-accounted CPU time and file I/O for each completed child process tree."""
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    yield
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    samples.setdefault(name, []).append({
        "user_ms": 1000 * (after.ru_utime - before.ru_utime),
        "system_ms": 1000 * (after.ru_stime - before.ru_stime),
        "minor_faults": after.ru_minflt - before.ru_minflt,
        "output_blocks": after.ru_oublock - before.ru_oublock,
    })


def environment(home):
    home.mkdir(exist_ok=True)
    return dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home), XDG_CACHE_HOME=str(home / ".cache"))


def multiply(client, value):
    response, elapsed = client.evaluate(f"nodeRepl.write(await math.mult({{a:{value},b:7}}))")
    if response.get("isError") or response.get("content") != [{"type": "text", "text": str(value * 7)}]:
        raise RuntimeError(f"Incorrect math.mult response: {response}")
    return elapsed


def measure(executable, directory, embedded, options, timings, profiles):
    def record(name, elapsed):
        timings.setdefault(name, []).append(elapsed)

    command = [str(executable), "--mcp"]
    env = environment(directory / "cli")
    with profile(profiles, "cli"):
        start = time.perf_counter_ns()
        output = subprocess.check_output([executable, "mult", "6", "7"], cwd=directory, env=env)
        record("cli", (time.perf_counter_ns() - start) / 1e6)
        if output.strip() != b"42":
            raise RuntimeError(f"Incorrect CLI result: {output!r}")
    if options.cli_only:
        return
    env = environment(directory / "metadata")
    with profile(profiles, "initialize_and_list"), closing(Client(command, env, directory)) as client:
        record("initialize", client.startup_ms)
        response, elapsed = client.request("tools/list", {})
        if "js" not in [tool["name"] for tool in response["tools"]]:
            raise RuntimeError(f"Missing js tool: {response}")
        record("tools_list", elapsed)

    home = directory / "evaluation"
    env = environment(home)
    for state in ("cold", "warm"):
        label = f"first_result_{state}"
        with profile(profiles, label):
            start = time.perf_counter_ns()
            with closing(Client(command, env, directory)) as client:
                multiply(client, 6)
                record(label, (time.perf_counter_ns() - start) / 1e6)
        if embedded:
            nodes = list(home.rglob("node"))
            workers = list(home.rglob("worker.mjs"))
            if len(nodes) != 1 or len(workers) != 1:
                raise RuntimeError("The embedded node and worker must be installed in the isolated home.")
            installed = [(path.stat().st_ino, path.stat().st_mtime_ns) for path in (nodes[0], workers[0])]
            if state == "cold":
                cold_files = installed
            elif installed != cold_files:
                raise RuntimeError("Warm launch replaced the installed runtime.")

    with profile(profiles, "repeated_rpc_session"), closing(Client(command, env, directory)) as client:
        multiply(client, 0)
        for value in range(1, options.calls + 1):
            record("math_mult", multiply(client, value))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before", type=Path, required=True)
    parser.add_argument("--after", type=Path, required=True)
    parser.add_argument("--rounds", type=int, default=24)
    parser.add_argument("--calls", type=int, default=32)
    parser.add_argument("--cli-only", action="store_true", help="Measure CLI launches, including identical-binary controls.")
    parser.add_argument("--output", type=Path, required=True)
    options = parser.parse_args()
    cycle = 4 if options.cli_only else 2
    if options.rounds < cycle or options.rounds % cycle or options.calls < 1:
        parser.error(f"Choose a positive multiple of {cycle} rounds and at least one RPC per session.")
    report = {"host": platform.platform(), "rounds": options.rounds, "calls": options.calls, "servers": {}}
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        executables = {}
        builds = [("before", options.before), ("after", options.after)]
        if options.cli_only:
            builds.extend([("before_control", options.before), ("after_control", options.after)])
        for name, source in builds:
            directory = root / name
            directory.mkdir()
            executable = directory / "math-complex"
            shutil.copy2(source, executable)
            if name.startswith("before"):
                for bundle in source.parent.glob("Replico_Replico*"):
                    if bundle.suffix in {".bundle", ".resources"}:
                        shutil.copytree(bundle, directory / bundle.name)
            executables[name] = executable
            report["servers"][name] = {
                **build_manifest(executable), "executable": str(source.resolve()),
                "installed_bytes": sum(path.stat().st_size for path in directory.rglob("*") if path.is_file()),
                "timings": {}, "profiles": {},
            }
        for index in range(-8 if options.cli_only else 0, options.rounds):
            # Four-period Williams design balances each copy's position and preceding binary.
            offsets = (0, 1, 3, 2) if options.cli_only else (0, 1)
            for offset in offsets:
                name = builds[(offset + index) % cycle][0]
                server = report["servers"][name]
                location = nullcontext(root) if options.cli_only else tempfile.TemporaryDirectory(dir=root)
                with location as sample:
                    measure(executables[name], Path(sample), name == "after", options,
                            server["timings"] if index >= 0 else {}, server["profiles"] if index >= 0 else {})
        if options.cli_only and any((root / "cli").rglob("node")):
            raise RuntimeError("Ordinary CLI calls unexpectedly installed Node.")
        for server in report["servers"].values():
            server["timings"] = {key: summarize(samples) for key, samples in server["timings"].items()}
    save(options.output, report)
    print(options.output)


if __name__ == "__main__":
    main()
