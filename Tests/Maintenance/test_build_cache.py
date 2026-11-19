import os
import tempfile
import unittest
from pathlib import Path

from scripts.build_cache import restore_timestamps


class BuildCacheTests(unittest.TestCase):
    def test_new_checkout_reuses_only_matching_inputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            original = 1_700_000_000_000_000_000
            fresh = original + 5_000_000_000
            names = ["unchanged", "edited", "executable", "removed"]
            for name in names:
                path = root / name
                path.write_bytes(b"old")
                os.utime(path, ns=(original, original))
            restore_timestamps(root, names)

            (root / "removed").unlink()
            (root / "added").write_bytes(b"new")
            (root / "edited").write_bytes(b"new")
            (root / "executable").chmod(0o755)
            os.utime(root / "unchanged", ns=(fresh, fresh))
            for name in ["edited", "executable"]:
                os.utime(root / name, ns=(original, original))
            added_time = (root / "added").stat().st_mtime_ns

            restore_timestamps(root, ["unchanged", "edited", "executable", "added"])
            self.assertEqual((root / "unchanged").stat().st_mtime_ns, original)
            edited_time = (root / "edited").stat().st_mtime_ns
            self.assertNotEqual(edited_time, original)
            self.assertNotEqual((root / "executable").stat().st_mtime_ns, original)
            self.assertEqual((root / "added").stat().st_mtime_ns, added_time)

            (root / "removed").write_bytes(b"old")
            for name in ["edited", "removed"]:
                os.utime(root / name, ns=(fresh, fresh))
            restore_timestamps(root, [*names, "added"])
            self.assertEqual((root / "edited").stat().st_mtime_ns, edited_time)
            self.assertEqual((root / "removed").stat().st_mtime_ns, fresh)

    def test_replacing_a_tracked_file_with_a_symlink_preserves_both_timestamps(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "checkout"
            root.mkdir()
            tracked = root / "input"
            original = 1_700_000_000_000_000_000
            tracked.write_bytes(b"same")
            os.utime(tracked, ns=(original, original))
            restore_timestamps(root, ["input"])

            target = root.parent / "external"
            target.write_bytes(tracked.read_bytes())
            tracked.unlink()
            tracked.symlink_to(target)
            target_time = original + 5_000_000_000
            link_time = original + 10_000_000_000
            os.utime(target, ns=(target_time, target_time))
            os.utime(tracked, ns=(link_time, link_time), follow_symlinks=False)
            restore_timestamps(root, ["input"])
            self.assertEqual(target.stat().st_mtime_ns, target_time)
            self.assertEqual(tracked.lstat().st_mtime_ns, link_time)
