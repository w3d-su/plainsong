#!/usr/bin/python3

"""Hash F2 artifact content, tree shape, and executable bits.

Resolved SwiftPM input mode seals the build-plan state, checkout bytes, and
binary artifacts. It deliberately excludes the bare-repository cache and Git
administrative data inside checkouts: Xcode mutates those after resolution even
when the bytes consumed by the build are unchanged.
"""

from __future__ import annotations

import hashlib
import os
import stat
import sys
from pathlib import Path


def update_field(digest: hashlib._Hash, value: bytes) -> None:
    digest.update(len(value).to_bytes(8, byteorder="big"))
    digest.update(value)


def update_entry_identity(
    digest: hashlib._Hash,
    path: Path,
    relative_path: str,
) -> os.stat_result:
    metadata = path.lstat()
    executable_mode = stat.S_IMODE(metadata.st_mode) & 0o111
    update_field(digest, relative_path.encode("utf-8", errors="surrogateescape"))
    update_field(digest, f"{executable_mode:o}".encode("ascii"))
    return metadata


def hash_entry(
    digest: hashlib._Hash,
    path: Path,
    relative_path: str,
    exclude_git_administration: bool = False,
) -> None:
    metadata = update_entry_identity(digest, path, relative_path)

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
            if exclude_git_administration and child.name == ".git":
                continue
            hash_entry(
                digest,
                child,
                f"{relative_path}/{child.name}",
                exclude_git_administration,
            )
        return

    raise ValueError(f"unsupported artifact entry type: {path}")


def require_entry_type(path: Path, expected_type: str) -> None:
    metadata = path.lstat()
    if expected_type == "directory" and stat.S_ISDIR(metadata.st_mode):
        return
    if expected_type == "file" and stat.S_ISREG(metadata.st_mode):
        return
    raise ValueError(f"expected {expected_type}: {path}")


def hash_resolved_package_input(digest: hashlib._Hash, path: Path) -> None:
    require_entry_type(path, "directory")
    allowed_names = {
        "artifacts",
        "checkouts",
        "repositories",
        "workspace-state.json",
    }
    unexpected_names = sorted(
        (child.name for child in path.iterdir() if child.name not in allowed_names),
        key=os.fsencode,
    )
    if unexpected_names:
        raise ValueError(
            "unexpected resolved package input entry: "
            + ", ".join(unexpected_names)
        )

    checkouts_path = path / "checkouts"
    artifacts_path = path / "artifacts"
    workspace_state_path = path / "workspace-state.json"
    require_entry_type(checkouts_path, "directory")
    require_entry_type(artifacts_path, "directory")
    require_entry_type(workspace_state_path, "file")
    repositories_path = path / "repositories"
    if repositories_path.exists() or repositories_path.is_symlink():
        require_entry_type(repositories_path, "directory")

    metadata = update_entry_identity(digest, path, "artifact")
    if not stat.S_ISDIR(metadata.st_mode):
        raise ValueError(f"expected directory: {path}")
    update_field(digest, b"directory")
    hashed_entries = (
        (artifacts_path, False),
        (checkouts_path, True),
        (workspace_state_path, False),
    )
    for child, exclude_git_administration in sorted(
        hashed_entries,
        key=lambda item: os.fsencode(item[0].name),
    ):
        hash_entry(
            digest,
            child,
            f"artifact/{child.name}",
            exclude_git_administration,
        )


def main() -> None:
    resolved_package_input = False
    if len(sys.argv) == 2:
        artifact_path = Path(sys.argv[1])
    elif len(sys.argv) == 3 and sys.argv[1] == "--resolved-package-input":
        resolved_package_input = True
        artifact_path = Path(sys.argv[2])
    else:
        print(
            f"usage: {sys.argv[0]} "
            "[--resolved-package-input] ARTIFACT_PATH",
            file=sys.stderr,
        )
        raise SystemExit(2)

    if not artifact_path.exists() and not artifact_path.is_symlink():
        print(f"artifact does not exist: {artifact_path}", file=sys.stderr)
        raise SystemExit(1)

    digest = hashlib.sha256()
    try:
        if resolved_package_input:
            hash_resolved_package_input(digest, artifact_path)
        else:
            hash_entry(digest, artifact_path, "artifact")
    except (OSError, ValueError) as error:
        print(f"could not hash artifact: {error}", file=sys.stderr)
        raise SystemExit(1)
    print(digest.hexdigest())


if __name__ == "__main__":
    main()
