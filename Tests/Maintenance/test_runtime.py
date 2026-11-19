#!/usr/bin/env python3
"""Focused checks for release input safety and reproducible runtime archives."""

import argparse
import io
import json
import stat
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile
from pathlib import Path

from scripts import runtime as artifacts


class RuntimeArtifactTests(unittest.TestCase):
    def test_versions_require_all_three_semver_components(self):
        for version in ["0.1.0", "1.2.3-rc.1+build.2", "10.0.0"]:
            self.assertEqual(artifacts.semantic_version(version), version)
        for version in ["1", "1.2", "01.2.3", "1.2.3-01", "1.2.3/other", "1.2.3;echo"]:
            with self.subTest(version=version), self.assertRaises(argparse.ArgumentTypeError):
                artifacts.semantic_version(version)

    def test_bumps_start_at_zero_and_use_the_largest_stable_semver(self):
        for bump, first, next_release in [
            ("major", "1.0.0", "3.0.0"), ("minor", "0.1.0", "2.11.0"), ("patch", "0.0.1", "2.10.5"),
        ]:
            with self.subTest(bump=bump):
                self.assertEqual(artifacts.select_version([], [], "merge", bump), first)
                tags = ["v2.10.4", "v2.9.99", "v91.0.0-rc.1", "v9.0.0+build", "v08.0.0", "other"]
                self.assertEqual(artifacts.select_version(tags, [], "merge", bump), next_release)

    def test_retry_keeps_its_original_version_after_later_releases_or_label_changes(self):
        original = artifacts.DescendantTag("v0.1.0", "release", ["merge"], ["M\tPackage.swift"])
        later = artifacts.DescendantTag("v0.1.1", "later-release", ["later-merge"], [])
        tags = [original.name, later.name]
        self.assertEqual(artifacts.select_version(tags, [later, original], "merge", "major"), "0.1.0")
        with self.assertRaisesRegex(RuntimeError, "older merge"):
            artifacts.select_version(tags, [later], "merge", "minor")

    def test_multiple_release_tags_and_conflicting_tag_trees_are_rejected(self):
        original = artifacts.DescendantTag("v1.0.0", "release", ["merge"], ["M\tPackage.swift"])
        duplicate = artifacts.DescendantTag("v2.0.0", "release", ["merge"], ["M\tPackage.swift"])
        with self.assertRaisesRegex(RuntimeError, "Multiple release tags"):
            artifacts.select_version([original.name, duplicate.name], [original, duplicate], "merge", "patch")
        for commit, parents, changes in [
            ("merge", ["parent"], []), ("release", ["merge", "other"], ["M\tPackage.swift"]),
            ("release", ["merge"], []), ("release", ["merge"], ["D\tPackage.swift"]),
            ("release", ["merge"], ["M\tPackage.swift", "M\tREADME.md"]),
        ]:
            with self.subTest(commit=commit, parents=parents, changes=changes):
                conflict = artifacts.DescendantTag("v1.0.1", commit, parents, changes)
                with self.assertRaisesRegex(RuntimeError, "expected release manifest"):
                    artifacts.select_version([original.name, conflict.name], [original, conflict], "merge", "patch")

    def test_repository_is_a_single_owner_and_repository(self):
        self.assertEqual(artifacts.repository_name("example/replico"), "example/replico")
        for repository in ["https://github.com/example/repo", "example/../repo", "../repo", "owner/..", "owner/repo?token=secret"]:
            with self.subTest(repository=repository), self.assertRaises(argparse.ArgumentTypeError):
                artifacts.repository_name(repository)

    def test_release_manifest_replaces_only_one_marker_block(self):
        prefix = '// swift-tools-version: 6.4\nimport PackageDescription\n\n'
        suffix = '\nlet package = Package(name: "Example")\n'
        source = prefix + '// BEGIN RUNTIME ARTIFACT\nold declaration\n// END RUNTIME ARTIFACT' + suffix
        replacement = artifacts.release_manifest(source, "https://github.com/example/repo/releases/download/v0.1.0/runtime.artifactbundleindex", "a" * 64)
        self.assertTrue(replacement.startswith(prefix + '// BEGIN RUNTIME ARTIFACT\n'))
        self.assertTrue(replacement.endswith('// END RUNTIME ARTIFACT' + suffix))
        self.assertNotIn('old declaration', replacement)
        self.assertIn('checksum: "' + "a" * 64 + '"', replacement)
        for invalid in [source + '\n// BEGIN RUNTIME ARTIFACT', source.replace('// END RUNTIME ARTIFACT', ''), '// END RUNTIME ARTIFACT\n// BEGIN RUNTIME ARTIFACT']:
            with self.subTest(source=invalid), self.assertRaises(RuntimeError):
                artifacts.release_manifest(invalid, "https://example.com/runtime", "a" * 64)

    def test_corrupt_cached_archives_are_rejected_without_replacement(self):
        with tempfile.TemporaryDirectory() as directory:
            runtime = Path(directory)
            downloads = runtime / "downloads"
            downloads.mkdir()
            archive = downloads / f"node-v{artifacts.NODE_VERSION}-darwin-arm64.tar.gz"
            archive.write_bytes(b"corrupt cache")
            with self.assertRaisesRegex(RuntimeError, "checksum mismatch"):
                artifacts.verified_archive(runtime, "darwin-arm64")
            self.assertEqual(archive.read_bytes(), b"corrupt cache")

    def test_release_uses_verified_reproducible_archives_and_a_versioned_manifest(self):
        target = "darwin-arm64"
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = Path(artifacts.__file__).resolve().parents[1] / "Package.swift"
            (root / "Package.swift").write_bytes(manifest.read_bytes())
            downloads = root / ".runtime/downloads"
            downloads.mkdir(parents=True)
            prefix = f"node-v{artifacts.NODE_VERSION}-{target}"
            archive = downloads / (prefix + ".tar.gz")
            with tarfile.open(archive, "w:gz") as source:
                for name, contents in [("bin/node", b"executable"), ("LICENSE", b"notices")]:
                    member = tarfile.TarInfo(f"{prefix}/{name}")
                    member.size = len(contents)
                    source.addfile(member, io.BytesIO(contents))
            spec = dict(artifacts.TARGETS[target], checksum=artifacts.digest(archive))
            with patch.object(artifacts, "TARGETS", {target: spec}):
                artifacts.release(root, "example/replico", "1.2.3", root / "publish")
                artifacts.release(root, None, "1.2.3", root / "local")
            index = next((root / "publish").glob("*.artifactbundleindex"))
            variant, = json.loads(index.read_bytes())["archives"]
            zipped = index.parent / variant["fileName"]
            self.assertEqual(variant["checksum"], artifacts.digest(zipped))
            self.assertEqual(zipped.read_bytes(), (root / "local" / zipped.name).read_bytes())
            with zipfile.ZipFile(zipped) as packed:
                bundle = artifacts.BUNDLE_NAME
                node = f"{bundle}/bin/node"
                self.assertEqual(packed.read(node), b"executable")
                self.assertEqual(stat.S_IMODE(packed.getinfo(node).external_attr >> 16), 0o755)
                self.assertEqual(packed.read(f"{bundle}/bin/LICENSE"), b"notices")
                info = json.loads(packed.read(f"{bundle}/info.json"))
                self.assertEqual(info["artifacts"]["node"]["variants"], [{"path": "bin/node", "supportedTriples": [spec["triple"]]}])
            staged = (index.parent / "Package.swift").read_text()
            self.assertIn(f"/releases/download/v1.2.3/{index.name}", staged)
            self.assertIn(artifacts.digest(index), staged)
            self.assertIn(artifacts.digest(zipped), (index.parent / "SHA256SUMS").read_text())
            self.assertFalse((root / "local/Package.swift").exists())
            self.assertEqual((root / "Package.swift").read_bytes(), manifest.read_bytes())


if __name__ == "__main__":
    unittest.main()
