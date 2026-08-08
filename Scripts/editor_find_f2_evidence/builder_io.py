"""Fail-closed filesystem primitives for the retained-evidence builder."""

from __future__ import annotations

import os
import re
import shutil
import stat
from pathlib import Path, PurePosixPath

from .errors import AuditError, require
from .strict_io import reject_acl_allows, reject_tree_acls, safe_relative_path, sha256_file


class DestinationRegistry:
    """Reserve destination paths and reject exact or case-folded collisions."""

    def __init__(self, root: Path) -> None:
        self.root = root
        self._paths: set[str] = set()
        self._folded: dict[str, str] = {}

    def reserve(self, destination: Path) -> None:
        relative = destination.relative_to(self.root).as_posix()
        safe_relative_path(relative, "builder destination")
        require(relative not in self._paths, f"destination already reserved: {relative}")
        parts = PurePosixPath(relative).parts
        for count in range(1, len(parts) + 1):
            component = PurePosixPath(*parts[:count]).as_posix()
            folded = component.casefold()
            existing = self._folded.get(folded)
            require(existing in (None, component), f"case-colliding destination: {component}")
            self._folded[folded] = component
        self._paths.add(relative)


def canonical_source(path: Path, kind: str, label: str) -> Path:
    require(path.is_absolute(), f"{label} must be absolute")
    try:
        resolved = path.resolve(strict=True)
        metadata = path.lstat()
    except OSError as error:
        raise AuditError(f"could not resolve {label}: {error}") from error
    require(resolved == path and not stat.S_ISLNK(metadata.st_mode), f"{label} is not canonical")
    require(metadata.st_uid == os.getuid(), f"{label} is not owned by the current user")
    require(not metadata.st_mode & 0o022, f"{label} is group/world-writable")
    expected = stat.S_ISREG(metadata.st_mode) if kind == "file" else stat.S_ISDIR(metadata.st_mode)
    require(expected, f"{label} is not a {kind}")
    reject_acl_allows(path, label)
    return path


def canonical_prefix(value: Path, label: str) -> Path:
    require(value.is_absolute(), f"{label} must be absolute")
    require(
        value.name not in ("", ".", "..")
        and re.fullmatch(r"[A-Za-z0-9._-]+", value.name) is not None,
        f"{label} leaf is unsafe",
    )
    parent = canonical_source(value.parent, "directory", f"{label} parent")
    require(parent / value.name == value, f"{label} is not canonical")
    return value


def create_fresh_root(path: Path, label: str) -> tuple[int, int]:
    require(path.is_absolute() and path.name not in ("", ".", ".."), f"{label} must be absolute")
    parent = canonical_source(path.parent, "directory", f"{label} parent")
    parent_metadata = parent.stat()
    require(parent_metadata.st_uid == os.getuid(), f"{label} parent is not owner controlled")
    require(stat.S_IMODE(parent_metadata.st_mode) == 0o700, f"{label} parent must have mode 0700")
    reject_tree_acls(parent, f"{label} parent")
    require(not path.exists() and not path.is_symlink(), f"{label} already exists")
    try:
        path.mkdir(mode=0o700)
    except FileExistsError as error:
        raise AuditError(f"{label} appeared while it was being created") from error
    path.chmod(0o700)
    metadata = path.stat()
    require(metadata.st_uid == os.getuid() and stat.S_IMODE(metadata.st_mode) == 0o700, f"{label} is not 0700")
    return metadata.st_dev, metadata.st_ino


def remove_fresh_root(path: Path, identity: tuple[int, int]) -> None:
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        return
    if (
        stat.S_ISDIR(metadata.st_mode)
        and not stat.S_ISLNK(metadata.st_mode)
        and (metadata.st_dev, metadata.st_ino) == identity
        and metadata.st_uid == os.getuid()
    ):
        shutil.rmtree(path)


def reject_tree_symlinks(path: Path, label: str, exclude_git: bool = False) -> None:
    canonical_source(path, "directory", label)
    folded: set[str] = set()
    for directory, directory_names, file_names in os.walk(path, topdown=True, followlinks=False):
        for name in directory_names + file_names:
            entry = Path(directory) / name
            relative = entry.relative_to(path).as_posix()
            metadata = entry.lstat()
            require(not stat.S_ISLNK(metadata.st_mode), f"{label} contains symlink: {relative}")
            require(metadata.st_uid == os.getuid(), f"{label} contains non-owner entry: {relative}")
            require(
                not metadata.st_mode & 0o022,
                f"{label} contains group/world-writable entry: {relative}",
            )
            require(
                stat.S_ISDIR(metadata.st_mode) or stat.S_ISREG(metadata.st_mode),
                f"{label} contains unsupported entry: {relative}",
            )
            require(relative.casefold() not in folded, f"{label} contains case collision: {relative}")
            folded.add(relative.casefold())
        if exclude_git:
            directory_names[:] = [name for name in directory_names if name != ".git"]
    reject_tree_acls(path, label)


def write_exclusive(path: Path, data: bytes, registry: DestinationRegistry, mode: int = 0o600) -> None:
    registry.reserve(path)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    try:
        with path.open("xb") as handle:
            handle.write(data)
    except FileExistsError as error:
        raise AuditError(f"refusing to overwrite builder output: {path}") from error
    path.chmod(mode)


def copy_file(source: Path, destination: Path, registry: DestinationRegistry) -> None:
    canonical_source(source, "file", f"copy source {source}")
    metadata = source.lstat()
    registry.reserve(destination)
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    try:
        source_fd = os.open(source, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        with os.fdopen(source_fd, "rb") as reader:
            opened = os.fstat(reader.fileno())
            require(
                stat.S_ISREG(opened.st_mode)
                and (opened.st_dev, opened.st_ino) == (metadata.st_dev, metadata.st_ino),
                f"copy source changed while opening: {source}",
            )
            destination_fd = os.open(
                destination,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
                0o600,
            )
            with os.fdopen(destination_fd, "wb") as writer:
                shutil.copyfileobj(reader, writer, length=1024 * 1024)
    except FileExistsError as error:
        raise AuditError(f"refusing to overwrite builder output: {destination}") from error
    destination.chmod(0o600 | (stat.S_IMODE(metadata.st_mode) & 0o111))
    require(sha256_file(source) == sha256_file(destination), f"copy changed bytes: {source}")


def _copy_tree_entry(
    source: Path,
    destination: Path,
    registry: DestinationRegistry,
    exclude_git: bool,
) -> None:
    metadata = source.lstat()
    require(not stat.S_ISLNK(metadata.st_mode), f"copy source contains symlink: {source}")
    registry.reserve(destination)
    if stat.S_ISREG(metadata.st_mode):
        with source.open("rb") as reader, destination.open("xb") as writer:
            shutil.copyfileobj(reader, writer, length=1024 * 1024)
    elif stat.S_ISDIR(metadata.st_mode):
        destination.mkdir(mode=0o700)
        for child in sorted(source.iterdir(), key=lambda item: os.fsencode(item.name)):
            if exclude_git and child.name == ".git":
                continue
            _copy_tree_entry(child, destination / child.name, registry, exclude_git)
    else:
        raise AuditError(f"copy source contains unsupported entry: {source}")
    destination.chmod(0o600 | (stat.S_IMODE(metadata.st_mode) & 0o111))


def copy_tree(
    source: Path,
    destination: Path,
    registry: DestinationRegistry,
    exclude_git: bool = False,
) -> None:
    reject_tree_symlinks(source, f"copy source {source}", exclude_git)
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    _copy_tree_entry(source, destination, registry, exclude_git)


def copy_resolved_package(
    source: Path,
    destination: Path,
    registry: DestinationRegistry,
) -> None:
    """Copy only the package bytes covered by resolved-package hashing."""

    reject_tree_symlinks(source, f"copy source {source}", exclude_git=True)
    metadata = source.lstat()
    registry.reserve(destination)
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    destination.mkdir(mode=0o700)
    copy_tree(source / "artifacts", destination / "artifacts", registry)
    copy_tree(source / "checkouts", destination / "checkouts", registry, exclude_git=True)
    copy_file(source / "workspace-state.json", destination / "workspace-state.json", registry)
    destination.chmod(0o600 | (stat.S_IMODE(metadata.st_mode) & 0o111))
