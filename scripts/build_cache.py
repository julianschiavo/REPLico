"""Keep unchanged checkout inputs at the timestamps Swift Build recorded in CI."""

import hashlib
import json
import os
import stat
import subprocess
from pathlib import Path


def restore_timestamps(root, paths):
    """Restore mtimes for matching file contents and permissions before SwiftPM builds."""
    manifest = root / ".build" / "input-timestamps.json"
    previous = json.loads(manifest.read_text()) if manifest.is_file() else {}
    current = {}
    for name in paths:
        path = root / name
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode):
            continue
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        timestamp = info.st_mtime_ns
        if name in previous:
            old_digest, old_mode, old_time = previous[name]
            if digest == old_digest and info.st_mode == old_mode:
                timestamp = old_time
            elif timestamp == old_time:
                # A same-size edit can otherwise match the cached compiler input exactly.
                timestamp += 1_000_000_000
        if timestamp != info.st_mtime_ns:
            os.utime(path, ns=(info.st_atime_ns, timestamp), follow_symlinks=False)
        current[name] = [digest, info.st_mode, timestamp]
    manifest.parent.mkdir(exist_ok=True)
    manifest.write_text(json.dumps(current))


if __name__ == "__main__":
    files = subprocess.check_output([
        "git", "ls-files", "-z", "--", "Package.swift", "Package.resolved", "Sources", "Tests", "Examples",
    ])
    restore_timestamps(Path.cwd(), [os.fsdecode(name) for name in files.split(b"\0") if name])
