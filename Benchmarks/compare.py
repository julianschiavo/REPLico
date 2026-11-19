#!/usr/bin/env python3
"""Compare two standalone MCP servers with the same synchronous stdio client.

Run from any directory. The servers use this repository as their working directory.
"""

from contextlib import ExitStack
import argparse
import base64
import hashlib
import json
import os
import platform
import statistics
import subprocess
import tempfile
import time
from pathlib import Path


REFERENCE_SERVER = "reference"


class Client:
    def __init__(self, command, environment, directory):
        self.diagnostics = tempfile.TemporaryFile()
        self.sequence = 0
        started = time.perf_counter_ns()
        self.process = subprocess.Popen(command, cwd=directory, env=environment, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=self.diagnostics)
        self.initialization, self.startup_ms = self.request("initialize", {
            "protocolVersion": "2025-11-25", "capabilities": {},
            "clientInfo": {"name": "replico-comparison", "version": "1.0"}
        }, started)
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def send(self, message):
        self.process.stdin.write(json.dumps(message, separators=(",", ":")).encode() + b"\n")
        self.process.stdin.flush()

    def request(self, method, parameters, started=None):
        self.sequence += 1
        started = time.perf_counter_ns() if started is None else started
        self.send({"jsonrpc": "2.0", "id": self.sequence, "method": method, "params": parameters})
        while True:
            frame = self.process.stdout.readline()
            if not frame:
                self.diagnostics.seek(0)
                raise RuntimeError(self.diagnostics.read().decode(errors="replace"))
            message = json.loads(frame)
            if message.get("id") == self.sequence:
                elapsed = (time.perf_counter_ns() - started) / 1_000_000
                if "error" in message:
                    raise RuntimeError(str(message["error"]))
                return message["result"], elapsed

    def tool(self, name, arguments):
        return self.request("tools/call", {"name": name, "arguments": arguments})

    def evaluate(self, code):
        return self.tool("js", {"code": code})

    def close(self):
        self.process.stdin.close()
        status = self.process.wait()
        self.process.stdout.close()
        self.diagnostics.seek(0)
        diagnostics = self.diagnostics.read().decode(errors="replace")
        self.diagnostics.close()
        if status:
            raise RuntimeError(f"Server exited {status}: {diagnostics}")


def summarize(samples):
    ordered = sorted(samples)
    return {"median_ms": statistics.median(samples), "p95_ms": ordered[(len(ordered) * 95 - 1) // 100],
            "samples_ms": samples}


def compatible(left, right):
    if bool(left.get("isError")) != bool(right.get("isError")):
        return False
    # A matching error outcome can have different wording or stack frames.
    return bool(left.get("isError")) or left.get("content", []) == right.get("content", [])


def check_sequence_result(response, expected, suite, cell):
    content = response.get("content", [])
    wanted = (expected["content"] if "content" in expected else
              [{"type": "text", "text": text} for text in expected["text"]])
    matches = bool(response.get("isError")) == expected["didFail"] and len(content) == len(wanted)
    if matches:
        for actual, item in zip(content, wanted):
            if item["type"] == "text":
                matches = actual.get("type") == "text" and actual.get("text") == item["text"]
            elif item["type"] == "image":
                matches = actual.get("type") == "image" and actual.get("mimeType") == item["mimeType"]
                if matches:
                    try:
                        data = base64.b64decode(actual.get("data", ""), validate=True)
                        matches = len(data) == item["byteCount"] and hashlib.sha256(data).hexdigest() == item["sha256"]
                    except (ValueError, TypeError):
                        matches = False
            else:
                matches = False
            if not matches:
                break
    if not matches:
        raise RuntimeError(f"Unexpected sequence output for {suite}, cell {cell + 1}")


def measure_sequence(suite, clients, order, sample, report):
    observations = {name: [] for name in order}
    for name in order:
        clients[name].tool("js_reset", {})
        warmup, _ = clients[name].evaluate("void 0")
        check_sequence_result(warmup, {"didFail": False, "text": [""]}, suite["name"], -1)
    for index, cell in enumerate(suite["cells"]):
        cell_order = order if (sample + index) % 2 == 0 else list(reversed(order))
        for name in cell_order:
            response, elapsed = clients[name].evaluate(cell["code"])
            check_sequence_result(response, cell["expected"], suite["name"], index)
            observations[name].append(elapsed)
    for name, cells in observations.items():
        report["servers"][name]["sequences"].setdefault(suite["name"], []).append(cells)


def run(options, servers, cases, sequences, repository):
    report = {"accuracy": [], "servers": {name: {
        "startup_ms": [], "cold_evaluation_ms": [], "workloads": {}, "sequences": {},
    } for name in servers}}
    accuracy = {}
    for name, server in servers.items():
        client = Client(server["command"], server["environment"], repository)
        try:
            accuracy[name] = []
            for case in cases:
                client.tool("js_reset", {})
                accuracy[name].append([client.evaluate(code)[0] for code in case["cells"]])
        finally:
            client.close()
    for index, case in enumerate(cases):
        left = accuracy["replico"][index]
        right = accuracy[REFERENCE_SERVER][index]
        report["accuracy"].append({"name": case["name"], "matches": all(map(compatible, left, right)),
                                   "replico": left, REFERENCE_SERVER: right})
    workloads = {
        "no_op": "void 0", "write": "nodeRepl.write(42)",
        "64KiB_input": "/*" + "." * 65532 + "*/",
        "1MiB_input": "/*" + "." * 1048572 + "*/",
        "1MiB_output": "nodeRepl.write('x'.repeat(1024 * 1024))",
        "1000_writes": "for (let i = 0; i < 1000; i++) nodeRepl.write('x')",
        "1000_bindings": "void 0", "5000_bindings": "void 0"
    }
    expected_output = {"write": "42", "1000_writes": "x" * 1000, "1MiB_output": "x" * 1048576}
    for round_index in range(options.rounds):
        order = list(servers) if round_index % 2 == 0 else list(reversed(servers))
        with ExitStack() as connections:
            clients = {}
            for name in order:
                server = servers[name]
                result = report["servers"][name]
                client = Client(server["command"], server["environment"], repository)
                connections.callback(client.close)
                clients[name] = client
                result["startup_ms"].append(client.startup_ms)
                cold, elapsed = client.evaluate("nodeRepl.write(42)")
                if cold.get("isError") or cold.get("content") != [{"type": "text", "text": "42"}]:
                    raise RuntimeError(str(cold))
                result["cold_evaluation_ms"].append(elapsed)
            for label, code in workloads.items():
                for name in order:
                    client = clients[name]
                    client.tool("js_reset", {})
                    if label.endswith("_bindings"):
                        count = int(label.split("_")[0])
                        response, _ = client.evaluate("\n".join(f"let b{i} = {i}" for i in range(count)))
                        if response.get("isError"):
                            raise RuntimeError(str(response))
                        probe, _ = client.evaluate(f"nodeRepl.write(JSON.stringify([b0, b{count - 1}]))")
                        if probe.get("content") != [{"type": "text", "text": f"[0,{count - 1}]"}]:
                            raise RuntimeError(f"Bindings were not retained for {name} {label}")
                for sample in range(options.samples + 3):
                    sample_order = order if sample % 2 == 0 else list(reversed(order))
                    for name in sample_order:
                        client = clients[name]
                        response, elapsed = client.evaluate(code)
                        if response.get("isError"):
                            raise RuntimeError(str(response))
                        expected = expected_output.get(label, "")
                        if response.get("content") != [{"type": "text", "text": expected}]:
                            raise RuntimeError(f"Unexpected output for {name} {label}")
                        if sample >= 3:
                            report["servers"][name]["workloads"].setdefault(label, []).append(elapsed)
            for suite in sequences["suites"]:
                for sample in range(options.sequence_samples):
                    measure_sequence(suite, clients, order, sample, report)
    for result in report["servers"].values():
        result["workloads"] = {name: summarize(samples) for name, samples in result["workloads"].items()}
        result["sequences"] = {
            name: {**summarize([sum(cells) for cells in samples]), "cell_samples_ms": samples}
            for name, samples in result["sequences"].items()
        }
    return report


def file_sha256(path):
    with Path(path).open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def build_manifest(executable):
    executable = executable.resolve()
    bundles = sorted([*executable.parent.glob("*.bundle"), *executable.parent.glob("*.resources")])
    return {
        "executable": str(executable), "executable_sha256": file_sha256(executable),
        "resource_sha256": {str(path.relative_to(executable.parent)): file_sha256(path)
                            for bundle in bundles for path in sorted(bundle.rglob("*")) if path.is_file()},
    }


def server_configuration(host, node, repository):
    host, node = host.resolve(), node.resolve()
    modules = host.parent.parent / "lib/node_modules"
    environment = dict(os.environ, REPLICO_NODE_PATH=str(node), NODE_REPL_NODE_PATH=str(node),
                       NODE_REPL_NODE_MODULE_DIRS=str(modules), NODE_REPL_TRUSTED_CODE_PATHS=f"{repository}:{modules}",
                       NODE_REPL_NATIVE_PIPE_CONNECT_TIMEOUT_MS="1000")
    environment.pop("CODEX_CLI_PATH", None)
    return {"command": [str(host)], "node": node, "environment": environment}


def artifacts(servers, fixtures, repository):
    return {
        "servers": {name: {**build_manifest(Path(server["command"][0])),
                           "node_executable": str(server["node"]), "node_executable_sha256": file_sha256(server["node"]),
                           "node": subprocess.check_output([server["node"], "--version"], text=True).strip()}
                    for name, server in servers.items()},
        "fixtures": {str(path.relative_to(repository)): file_sha256(path) for path in fixtures},
    }


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--agent", type=Path, required=True)
    parser.add_argument("--node", type=Path, required=True)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--reference-node", type=Path, required=True)
    parser.add_argument("--samples", type=int, default=30)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--sequence-samples", type=int, default=5,
                        help="Fresh, prewarmed replays per suite per round; zero disables sequences.")
    parser.add_argument("--output", type=Path, required=True)
    options = parser.parse_args()
    if options.samples < 1 or options.rounds < 1 or options.sequence_samples < 0:
        parser.error("Samples and rounds must be positive; sequence samples cannot be negative.")
    repository = Path(__file__).resolve().parent.parent
    servers = {"replico": server_configuration(options.agent, options.node, repository),
               REFERENCE_SERVER: server_configuration(options.reference, options.reference_node, repository)}
    fixtures = repository / "Benchmarks"
    cases = json.loads((fixtures / "compatibility.json").read_text())
    sequences = json.loads((fixtures / "sequences.json").read_text())
    if sequences["schemaVersion"] != 1:
        parser.error("Unsupported sequence fixture version")
    if not options.sequence_samples:
        sequences["suites"] = []
    inputs = sorted(path for path in fixtures.rglob("*") if path.suffix in {".json", ".jpg", ".png", ".gif", ".webp"})
    before = artifacts(servers, inputs, repository)
    report = run(options, servers, cases, sequences, repository)
    if artifacts(servers, inputs, repository) != before:
        raise RuntimeError("The executables or fixtures changed during timing")
    for name, result in report["servers"].items():
        result.update(before["servers"][name], command=servers[name]["command"])
    report.update(host=platform.platform(), rounds=options.rounds, samples_per_round=options.samples,
                  sequence_samples_per_round=options.sequence_samples, fixture_sha256=before["fixtures"],
                  driver_sha256=file_sha256(__file__))
    save(options.output, report)
    print(f"Compatibility: {sum(case['matches'] for case in report['accuracy'])}/{len(cases)} cases")
    for name, result in report["servers"].items():
        for label in ("workloads", "sequences"):
            print(name, label, {key: round(value["median_ms"], 3) for key, value in result[label].items()})
    print(options.output)


if __name__ == "__main__":
    main()
