"""Exact in-process equivalent of hash-editor-find-f2-artifact.py."""

from __future__ import annotations

import hashlib
import os
import stat
import tarfile
from pathlib import Path
from pathlib import PurePosixPath

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


def _safe_archive_name(member: tarfile.TarInfo) -> str:
    name = member.name[:-1] if member.isdir() and member.name.endswith("/") else member.name
    pure = PurePosixPath(name)
    require(
        name
        and not pure.is_absolute()
        and pure.as_posix() == name
        and all(part not in ("", ".", "..") for part in pure.parts),
        f"unsafe source archive member: {member.name}",
    )
    return name


def _safe_symlink_target(name: str, target: str) -> None:
    pure = PurePosixPath(target)
    require(target and not pure.is_absolute(), f"unsafe source archive symlink: {name}")
    pending: list[str] = list(PurePosixPath(name).parent.parts)
    for part in pure.parts:
        if part in ("", "."):
            continue
        if part == "..":
            require(bool(pending), f"source archive symlink escapes root: {name}")
            pending.pop()
        else:
            pending.append(part)


def hash_source_archive_tree(path: Path) -> str:
    """Hash the logical tree of an uncompressed Git source archive without extracting it."""

    metadata = path.lstat()
    require(stat.S_ISREG(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode), "source archive is not a regular file")
    try:
        archive = tarfile.open(path, mode="r:")
    except (OSError, tarfile.TarError) as error:
        raise AuditError(f"source archive is not a valid uncompressed tar: {error}") from error
    with archive:
        members: dict[str, tarfile.TarInfo] = {}
        folded: set[str] = set()
        for member in archive.getmembers():
            name = _safe_archive_name(member)
            require(name not in members, f"duplicate source archive member: {name}")
            require(name.casefold() not in folded, f"case-colliding source archive member: {name}")
            require(
                member.isdir() or member.isreg() or member.issym(),
                f"unsupported source archive member: {name}",
            )
            if member.issym():
                _safe_symlink_target(name, member.linkname)
            members[name] = member
            folded.add(name.casefold())
        require(bool(members), "source archive is empty")
        for name in members:
            parent = PurePosixPath(name).parent
            if parent != PurePosixPath("."):
                require(
                    parent.as_posix() in members and members[parent.as_posix()].isdir(),
                    f"source archive parent directory is missing: {name}",
                )

        digest = hashlib.sha256()
        _field(digest, b"artifact")
        # Git archives do not contain the extraction root itself. The measured
        # source-tree hash was created under the conventional 0755 root.
        _field(digest, b"111")
        _field(digest, b"directory")

        def append(name: str) -> None:
            member = members[name]
            _field(digest, f"artifact/{name}".encode("utf-8", errors="surrogateescape"))
            _field(digest, f"{member.mode & 0o111:o}".encode("ascii"))
            if member.isdir():
                _field(digest, b"directory")
                prefix = f"{name}/"
                children = (
                    candidate
                    for candidate in members
                    if candidate.startswith(prefix)
                    and "/" not in candidate[len(prefix):]
                )
                for child in sorted(children, key=os.fsencode):
                    append(child)
            elif member.isreg():
                _field(digest, b"file")
                _field(digest, member.size.to_bytes(8, "big"))
                stream = archive.extractfile(member)
                require(stream is not None, f"could not read source archive member: {name}")
                read = 0
                with stream:
                    while chunk := stream.read(1024 * 1024):
                        read += len(chunk)
                        digest.update(chunk)
                require(read == member.size, f"source archive member size differs: {name}")
            else:
                _field(digest, b"symlink")
                _field(digest, member.linkname.encode("utf-8", errors="surrogateescape"))

        for top_level in sorted(
            (name for name in members if "/" not in name),
            key=os.fsencode,
        ):
            append(top_level)
        return digest.hexdigest()
