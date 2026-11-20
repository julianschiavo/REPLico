#!/usr/bin/env python3
"""Prepare verified runtime assets locally without publishing or changing Package.swift."""

import argparse
import gzip
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import tarfile
import tempfile
import zipfile
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import quote


NODE_VERSION = "26.13.1"
TARGETS = {
    "darwin-arm64": {
        "extension": "tar.gz",
        "checksum": "aec2514ea1ceb2ba52455e9ec65986f6749a06dd759e5db2a72e6889668c9735",
        "triple": "arm64-apple-macosx",
    },
    "linux-arm64": {
        "extension": "tar.xz",
        "checksum": "89e1853138db51e8b82d3e98ba9c0d3f2956a28e5e55ea1b7e12d25aae92d5dd",
        "triple": "aarch64-unknown-linux-gnu",
    },
    "linux-x64": {
        "extension": "tar.xz",
        "checksum": "5c063e46bab0fbc1c17cc445d7ff129cbdcd0471be6ed83b6ab864f8143bc864",
        "triple": "x86_64-unknown-linux-gnu",
    },
}
BUNDLE_NAME = "ReplicoRuntime.artifactbundle"
ARTIFACT = "ReplicoRuntimeArtifact"
COMPILER_INPUTS = Path(__file__).with_name("runtime").resolve()


def digest(path):
    checksum = hashlib.sha256()
    with path.open("rb") as source:
        while block := source.read(1024 * 1024):
            checksum.update(block)
    return checksum.hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def semantic_version(value):
    match = re.fullmatch(
        r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
        r"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?", value
    )
    if not match or any(part.isdigit() and len(part) > 1 and part.startswith("0") for part in (match[4] or "").split(".")):
        raise argparse.ArgumentTypeError("Use a full semantic version, such as 0.1.0 or 0.1.0-rc.1.")
    return value


STABLE_TAG = re.compile(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")


@dataclass(frozen=True)
class DescendantTag:
    """A stable tag whose commit contains the merge under consideration."""
    name: str
    commit: str
    parents: list[str]
    changes: list[str]


def select_version(names, descendants, merge, bump):
    versions = [tuple(map(int, match.groups())) for name in names if (match := STABLE_TAG.fullmatch(name))]
    retries = []
    for tag in descendants:
        if merge in tag.parents or tag.commit == merge:
            if tag.parents != [merge] or tag.changes != ["M\tPackage.swift"]:
                raise RuntimeError(f"{tag.name} already refers to this merge without the expected release manifest change.")
            retries.append(tag.name)
    if len(retries) > 1:
        raise RuntimeError(f"Multiple release tags for the same merge: {', '.join(retries)}")
    if retries:
        return retries[0][1:]
    if descendants:
        raise RuntimeError("A later merge already has a release tag. Refusing to release an older merge.")
    version = list(max(versions, default=(0, 0, 0)))
    part = ("major", "minor", "patch").index(bump)
    version[part] += 1
    version[part + 1:] = [0] * (2 - part)
    return ".".join(map(str, version))


def next_version(repository, merge, bump):
    def git(*arguments):
        return subprocess.check_output(["git", *arguments], cwd=repository, text=True).splitlines()

    if not re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", merge):
        raise RuntimeError("Expected a full lowercase merge commit SHA.")
    names = git("tag", "--list", "v*", "--format=%(refname:strip=2)")
    descendants = []
    for name in git("tag", "--contains", merge, "--list", "v*", "--format=%(refname:strip=2)"):
        if not STABLE_TAG.fullmatch(name):
            continue
        ref = f"refs/tags/{name}^{{commit}}"
        commit, *parents = git("rev-list", "-1", "--parents", ref, "--")[0].split()
        changes = git("diff", "--name-status", "--no-renames", merge, commit, "--") if parents == [merge] else []
        descendants.append(DescendantTag(name, commit, parents, changes))
    return select_version(names, descendants, merge, bump)


def repository_name(value):
    if not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?/[A-Za-z0-9._-]{1,100}", value):
        raise argparse.ArgumentTypeError("Use a GitHub repository in owner/repo form.")
    if value.split("/")[1] in {".", ".."}:
        raise argparse.ArgumentTypeError("Use a GitHub repository in owner/repo form.")
    return value


def host_target():
    targets = {("Darwin", "arm64"): "darwin-arm64", ("Linux", "aarch64"): "linux-arm64", ("Linux", "x86_64"): "linux-x64"}
    try:
        return targets[(platform.system(), platform.machine())]
    except KeyError:
        raise RuntimeError("Runtime preparation supports macOS arm64 and Linux arm64/x64.") from None


def verified_archive(runtime, target):
    specification = TARGETS[target]
    name = f"node-v{NODE_VERSION}-{target}.{specification['extension']}"
    directory = runtime / "downloads"
    directory.mkdir(parents=True, exist_ok=True)
    archive = directory / name
    if archive.exists():
        if digest(archive) != specification["checksum"]:
            raise RuntimeError(f"Node archive checksum mismatch: {archive}")
    else:
        with tempfile.TemporaryDirectory(prefix="download-", dir=directory) as staging:
            downloaded = Path(staging) / name
            subprocess.run(["curl", "--fail", "--location", f"https://nodejs.org/dist/v{NODE_VERSION}/{name}", "--output", downloaded], check=True)
            if digest(downloaded) != specification["checksum"]:
                raise RuntimeError(f"Node archive checksum mismatch: {name}")
            downloaded.replace(archive)
    return archive


def embed_node(bundle, target):
    """Cross-assemble read-only data. The importing compiler builds the fd API against its own libc and zlib."""
    node = bundle / "bin/node"
    license = bundle / "bin/LICENSE"
    include = bundle / "include"
    include.mkdir()
    triple = TARGETS[target]["triple"]
    apple = target.startswith("darwin-")
    with tempfile.TemporaryDirectory(dir=bundle.parent) as temporary:
        work = Path(temporary)
        shutil.copyfile(license, work / "LICENSE")
        compressed = work / "node.gz"
        with node.open("rb") as source, compressed.open("wb") as output:
            with gzip.GzipFile(filename="", fileobj=output, mode="wb", mtime=0, compresslevel=6) as gz:
                shutil.copyfileobj(source, gz)
        (include / "NodeIdentity.h").write_text(
            f'#define REPLICO_NODE_VERSION "{NODE_VERSION}"\n'
            f'#define REPLICO_NODE_SHA256 "{digest(node)}"\n'
            f'#define REPLICO_NODE_SIZE {node.stat().st_size}\n'
            f'#define REPLICO_NODE_GZIP_SIZE {compressed.stat().st_size}\n'
            f'#define REPLICO_NODE_LICENSE_SIZE {license.stat().st_size}\n'
        )
        subprocess.run(["clang", "-target", triple + ("26.0" if apple else ""), "-c",
                        COMPILER_INPUTS / "NodePayload.S", "-o", "node.o"], cwd=work, check=True)
        (work / "node.o").chmod(0o644)
        library = bundle / f"lib{ARTIFACT}.a"
        if archiver := shutil.which("llvm-ar"):
            command = [archiver, "--format=" + ("darwin" if apple else "gnu"), "rcsD"]
        elif target == host_target():
            command = ["ar", "rcs"]
        else:
            raise RuntimeError("Cross-platform release packaging requires llvm-ar in PATH.")
        subprocess.run([*command, library, "node.o"], cwd=work, check=True, env=dict(os.environ, ZERO_AR_DATE="1"))
    shutil.copyfile(COMPILER_INPUTS / f"{ARTIFACT}.h", include / f"{ARTIFACT}.h")
    (include / "module.modulemap").write_text(
        f'module {ARTIFACT} {{\n    header "{ARTIFACT}.h"\n    link "z"\n    export *\n}}\n'
    )
    return {
        "path": library.name,
        "supportedTriples": [triple],
        "staticLibraryMetadata": {"headerPaths": ["include"], "moduleMapPath": "include/module.modulemap"},
    }


def make_bundle(destination, target, archive, *, development=False):
    variant = destination / "bin"
    variant.mkdir(parents=True)
    root = f"node-v{NODE_VERSION}-{target}"
    with tarfile.open(archive) as source:
        for member, name, mode in [(f"{root}/bin/node", "node", 0o755), (f"{root}/LICENSE", "LICENSE", 0o644)]:
            with source.extractfile(member) as content, (variant / name).open("wb") as output:
                shutil.copyfileobj(content, output)
            (variant / name).chmod(mode)
    write_json(variant / "PROVENANCE.json", {
        "nodeVersion": NODE_VERSION,
        "nodeArchiveURL": f"https://nodejs.org/dist/v{NODE_VERSION}/{archive.name}",
        "nodeArchiveSHA256": TARGETS[target]["checksum"],
        "licenses": "Node's LICENSE includes its third-party notices.",
    })
    library = embed_node(destination, target)
    if not development:
        (variant / "node").unlink()
    write_json(destination / "info.json", {
        "schemaVersion": "1.0",
        "artifacts": {ARTIFACT: {"type": "staticLibrary", "version": NODE_VERSION, "variants": [library]}},
    })


def replace_bundle(staging, destination):
    backup = destination.with_suffix(".previous")
    if backup.exists():
        raise RuntimeError(f"Refusing to replace an unfinished backup: {backup}")
    if destination.exists():
        destination.replace(backup)
    try:
        staging.replace(destination)
    except BaseException:
        if backup.exists():
            backup.replace(destination)
        raise
    if backup.exists():
        shutil.rmtree(backup)


def prepare(repository):
    runtime = repository / ".runtime"
    runtime.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="artifact-", dir=runtime) as temporary:
        staged = Path(temporary) / BUNDLE_NAME
        target = host_target()
        make_bundle(staged, target, verified_archive(runtime, target), development=True)
        replace_bundle(staged, runtime / BUNDLE_NAME)
    print(f"Prepared local runtime artifact: {runtime / BUNDLE_NAME}")


def deterministic_zip(bundle, destination):
    with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for path in sorted(bundle.rglob("*")):
            if not path.is_file():
                continue
            relative = path.relative_to(bundle.parent).as_posix()
            metadata = zipfile.ZipInfo(relative, date_time=(1980, 1, 1, 0, 0, 0))
            metadata.create_system = 3
            metadata.compress_type = zipfile.ZIP_STORED if path.suffix == ".a" else zipfile.ZIP_DEFLATED
            metadata.external_attr = (0o100755 if path.stat().st_mode & 0o111 else 0o100644) << 16
            with path.open("rb") as source, archive.open(metadata, "w") as output:
                shutil.copyfileobj(source, output)


def release_manifest(source, url, checksum):
    begin = "// BEGIN RUNTIME ARTIFACT"
    end = "// END RUNTIME ARTIFACT"
    if source.count(begin) != 1 or source.count(end) != 1:
        raise RuntimeError("Package.swift must contain exactly one runtime artifact marker block.")
    start = source.index(begin) + len(begin)
    finish = source.index(end)
    if finish < start:
        raise RuntimeError("Package.swift runtime artifact markers are reversed.")
    declaration = (
        '\nlet runtimeTarget: Target = .binaryTarget(\n'
        '    name: "ReplicoRuntimeArtifact",\n'
        f'    url: {json.dumps(url)},\n'
        f'    checksum: {json.dumps(checksum)}\n'
        ')\n'
    )
    return source[:start] + declaration + source[finish:]


def release(repository, owner_repo, version, output):
    if output.exists() and any(output.iterdir()):
        raise RuntimeError(f"Release output must be empty: {output}")
    runtime = repository / ".runtime"
    runtime.mkdir(exist_ok=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="release-", dir=output.parent) as temporary:
        staging = Path(temporary)
        archives = []
        for target in TARGETS:
            with tempfile.TemporaryDirectory(prefix="bundle-", dir=runtime) as bundle_directory:
                bundle = Path(bundle_directory) / BUNDLE_NAME
                make_bundle(bundle, target, verified_archive(runtime, target))
                filename = f"ReplicoRuntime-{version}-{target}.artifactbundle.zip"
                deterministic_zip(bundle, staging / filename)
            archives.append({"fileName": filename, "checksum": digest(staging / filename), "supportedTriples": [TARGETS[target]["triple"]]})
        index = staging / f"ReplicoRuntime-{version}.artifactbundleindex"
        write_json(index, {"schemaVersion": "1.0", "archives": archives})
        sums = {entry["fileName"]: entry["checksum"] for entry in archives}
        sums[index.name] = digest(index)
        if owner_repo:
            url = f"https://github.com/{owner_repo}/releases/download/{quote('v' + version, safe='')}/{quote(index.name)}"
            manifest = staging / "Package.swift"
            manifest.write_text(release_manifest((repository / "Package.swift").read_text(), url, sums[index.name]))
            sums[manifest.name] = digest(manifest)
        (staging / "SHA256SUMS").write_text("".join(f"{value}  {name}\n" for name, value in sorted(sums.items())))
        if output.exists():
            output.rmdir()
        staging.replace(output)
    print(f"Staged unpublished release assets: {output}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("prepare")
    version_parser = commands.add_parser("next-version", help="Select or recover the release version for a merged commit.")
    version_parser.add_argument("--merge", required=True)
    version_parser.add_argument("--bump", choices=["major", "minor", "patch"], required=True)
    release_parser = commands.add_parser("release")
    release_parser.add_argument("--repository", type=repository_name, help="Add fixed GitHub Release URLs and an inactive release Package.swift.")
    release_parser.add_argument("--version", type=semantic_version, required=True)
    release_parser.add_argument("--output", type=Path)
    arguments = parser.parse_args()
    repository = Path(__file__).resolve().parent.parent
    try:
        if arguments.command == "prepare":
            prepare(repository)
        elif arguments.command == "next-version":
            print(next_version(repository, arguments.merge, arguments.bump))
        else:
            output = arguments.output or repository / ".runtime/releases" / arguments.version
            release(repository, arguments.repository, arguments.version, output.resolve())
    except (OSError, RuntimeError, subprocess.CalledProcessError, tarfile.TarError, zipfile.BadZipFile) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
