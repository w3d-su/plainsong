#!/usr/bin/python3

"""Hash F2 artifact content, tree shape, and executable bits."""

from __future__ import annotations

import hashlib
import os
import stat
import sys
from pathlib import Path


def update_field(digest: hashlib._Hash, value: bytes) -> None:
    digest.update(len(value).to_bytes(8, byteorder="big"))
    digest.update(value)


def hash_entry(digest: hashlib._Hash, path: Path, relative_path: str) -> None:
    metadata = path.lstat()
    executable_mode = stat.S_IMODE(metadata.st_mode) & 0o111
    update_field(digest, relative_path.encode("utf-8", errors="surrogateescape"))
    update_field(digest, f"{executable_mode:o}".encode("ascii"))

    if stat.S_ISLNK(metadata.st_mode):
        update_field(digest, b"symlink")
        update_field(
            digest,
            os.readlink(path).encode("utf-8", errors="surrogateescape"),
        )
        return

    if stat.S_ISREG(metadata.st_mode):
        update_field(digest, b"file")
        update_field(digest, metadata.st_size.to_bytes(8, byteorder="big"))
        with path.open("rb") as handle:
            while chunk := handle.read(1024 * 1024):
                digest.update(chunk)
        return

    if stat.S_ISDIR(metadata.st_mode):
        update_field(digest, b"directory")
        for child in sorted(path.iterdir(), key=lambda item: os.fsencode(item.name)):
            hash_entry(digest, child, f"{relative_path}/{child.name}")
        return

    raise ValueError(f"unsupported artifact entry type: {path}")


def main() -> None:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} ARTIFACT_PATH", file=sys.stderr)
        raise SystemExit(2)

    artifact_path = Path(sys.argv[1])
    if not artifact_path.exists() and not artifact_path.is_symlink():
        print(f"artifact does not exist: {artifact_path}", file=sys.stderr)
        raise SystemExit(1)

    digest = hashlib.sha256()
    try:
        hash_entry(digest, artifact_path, "artifact")
    except (OSError, ValueError) as error:
        print(f"could not hash artifact: {error}", file=sys.stderr)
        raise SystemExit(1)
    print(digest.hexdigest())


if __name__ == "__main__":
    main()
