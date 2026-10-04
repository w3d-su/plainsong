#!/usr/bin/env python3
"""Inspect only declared test resources; retain partial diagnostics on the first error."""
import argparse
import errno
import hashlib
import json
import os
from pathlib import Path
import stat
import sys


def inspect_file(root, relative):
    path = root / relative
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        metadata = os.fstat(fd)
        if not stat.S_ISREG(metadata.st_mode):
            raise OSError(errno.EINVAL, "not a regular resource", str(path))
        if metadata.st_size == 0:
            raise OSError(errno.EINVAL, "empty resource", str(path))
        digest = hashlib.sha256()
        content = bytearray()
        byte_count = 0
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            digest.update(chunk)
            byte_count += len(chunk)
            if relative == "performance-required-resources.txt":
                content.extend(chunk)
        if byte_count != metadata.st_size:
            raise OSError(errno.EIO, "resource size changed while reading", str(path))
        return {
            "path": relative,
            "bytes": metadata.st_size,
            "permissions": oct(stat.S_IMODE(metadata.st_mode)),
            "sha256": digest.hexdigest(),
        }, content
    finally:
        os.close(fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("manifest", type=Path)
    args = parser.parse_args()
    root = args.bundle / "Contents/Resources"
    manifest = {"bundle": str(args.bundle), "resources": [], "status": "failed"}
    relative = "performance-required-resources.txt"
    try:
        entry, content = inspect_file(root, relative)
        manifest["resources"].append(entry)
        paths = content.decode("utf-8").splitlines()
        if not paths:
            raise OSError(errno.EINVAL, "empty resource contract", str(root / relative))
        for relative in paths:
            if not relative or Path(relative).is_absolute() or ".." in Path(relative).parts:
                raise OSError(errno.EINVAL, "invalid resource contract path", relative)
            entry, _ = inspect_file(root, relative)
            manifest["resources"].append(entry)
        manifest["status"] = "passed"
        print(f"PerformanceTests preflight bundle={args.bundle}")
        print("Resources: " + ", ".join(entry["path"] for entry in manifest["resources"]))
        return 0
    except (OSError, UnicodeError) as error:
        error_number = error.errno if isinstance(error, OSError) else errno.EILSEQ
        message = (f"PerformanceTests resource preflight failed: path={root / relative} "
                   f"errno={error_number} ({error}) bundle={args.bundle}")
        manifest["error"] = message
        print(message, file=sys.stderr)
        return 1
    finally:
        args.manifest.parent.mkdir(parents=True, exist_ok=True)
        args.manifest.write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    sys.exit(main())
