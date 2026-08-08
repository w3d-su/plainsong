"""Exact in-process equivalent of hash-editor-find-f2-artifact.py."""

from __future__ import annotations

import hashlib
import os
import stat
from pathlib import Path

from .errors import AuditError, require


def _field(digest: object, value: bytes) -> None:
    digest.update(len(value).to_bytes(8, "big"))
    digest.update(value)


def _entry(digest: object, path: Path, relative: str, exclude_git: bool = False) -> None:
    metadata = path.lstat()
    executable = stat.S_IMODE(metadata.st_mode) & 0o111
    _field(digest, relative.encode("utf-8", errors="surrogateescape"))
    _field(digest, f"{executable:o}".encode("ascii"))
    if stat.S_ISLNK(metadata.st_mode):
        _field(digest, b"symlink")
        _field(digest, os.readlink(path).encode("utf-8", errors="surrogateescape"))
    elif stat.S_ISREG(metadata.st_mode):
        _field(digest, b"file")
        _field(digest, metadata.st_size.to_bytes(8, "big"))
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        with os.fdopen(descriptor, "rb") as handle:
            opened = os.fstat(handle.fileno())
            require(
                stat.S_ISREG(opened.st_mode)
                and (opened.st_dev, opened.st_ino)
                == (metadata.st_dev, metadata.st_ino),
                f"artifact file changed while opening: {path}",
            )
            while chunk := handle.read(1024 * 1024):
                digest.update(chunk)
    elif stat.S_ISDIR(metadata.st_mode):
        _field(digest, b"directory")
        for child in sorted(path.iterdir(), key=lambda item: os.fsencode(item.name)):
            if exclude_git and child.name == ".git":
                continue
            _entry(digest, child, f"{relative}/{child.name}", exclude_git)
    else:
        raise AuditError(f"unsupported artifact entry: {path}")


def hash_artifact(path: Path, resolved_package: bool = False) -> str:
    digest = hashlib.sha256()
    if not resolved_package:
        _entry(digest, path, "artifact")
        return digest.hexdigest()
    require(path.is_dir() and not path.is_symlink(), "resolved package input is not a directory")
    children = {child.name: child for child in path.iterdir()}
    require(set(children) <= {"artifacts", "checkouts", "repositories", "workspace-state.json"}, "unexpected package input entry")
    for name in ("artifacts", "checkouts"):
        require(name in children and children[name].is_dir(), f"missing package {name}")
    require(
        "workspace-state.json" in children
        and children["workspace-state.json"].is_file(),
        "missing package workspace state",
    )
    metadata = path.lstat()
    _field(digest, b"artifact")
    _field(digest, f"{stat.S_IMODE(metadata.st_mode) & 0o111:o}".encode("ascii"))
    _field(digest, b"directory")
    for name, exclude_git in (("artifacts", False), ("checkouts", True), ("workspace-state.json", False)):
        _entry(digest, children[name], f"artifact/{name}", exclude_git)
    return digest.hexdigest()
