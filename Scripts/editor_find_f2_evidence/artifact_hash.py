"""Exact in-process equivalent of hash-editor-find-f2-artifact.py."""

from __future__ import annotations

import hashlib
import os
import stat
import tarfile
from pathlib import Path
from pathlib import PurePosixPath

from .errors import AuditError, require

GENERATED_SOURCE_ADDITIONS = ("Plainsong.xcodeproj",)
GENERATED_SOURCE_FILES = ("App/Info.plist", "App/Plainsong.entitlements")


def _field(digest: object, value: bytes) -> None:
    digest.update(len(value).to_bytes(8, "big"))
    digest.update(value)


def _entry(
    digest: object,
    path: Path,
    relative: str,
    exclude_git: bool = False,
    executable_override: int | None = None,
) -> None:
    metadata = path.lstat()
    executable = (
        stat.S_IMODE(metadata.st_mode) & 0o111
        if executable_override is None
        else executable_override
    )
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


def hash_source_tree(path: Path) -> str:
    """Hash an extracted Git tree with a canonical synthetic 0755 root."""

    require(path.is_dir() and not path.is_symlink(), "source tree is not a directory")
    digest = hashlib.sha256()
    _entry(digest, path, "artifact", executable_override=0o111)
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


def _source_archive_members(archive: tarfile.TarFile) -> dict[str, tarfile.TarInfo]:
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
    return members


def _open_source_archive(path: Path) -> tarfile.TarFile:
    metadata = path.lstat()
    require(
        stat.S_ISREG(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode),
        "source archive is not a regular file",
    )
    try:
        return tarfile.open(path, mode="r:")
    except (OSError, tarfile.TarError) as error:
        raise AuditError(f"source archive is not a valid uncompressed tar: {error}") from error


def validate_source_snapshot(
    archive_path: Path,
    snapshot_path: Path,
    generated_additions: tuple[str, ...] = GENERATED_SOURCE_ADDITIONS,
) -> None:
    """Bind archived members to a snapshot plus named generated-only roots."""

    require(
        snapshot_path.is_dir() and not snapshot_path.is_symlink(),
        "source snapshot is not a directory",
    )
    actual: dict[str, os.stat_result] = {}
    for directory, directory_names, file_names in os.walk(
        snapshot_path,
        topdown=True,
        followlinks=False,
    ):
        for name in directory_names + file_names:
            path = Path(directory) / name
            relative = path.relative_to(snapshot_path).as_posix()
            actual[relative] = path.lstat()
    allowed_roots = set(generated_additions)
    require(
        all(
            PurePosixPath(item).as_posix() == item
            and len(PurePosixPath(item).parts) == 1
            and item not in ("", ".", "..")
            for item in allowed_roots
        ),
        "generated source addition is unsafe",
    )
    with _open_source_archive(archive_path) as archive:
        members = _source_archive_members(archive)
        extras = set(actual) - set(members)

        def is_generated_addition(relative: str) -> bool:
            parts = PurePosixPath(relative).parts
            if parts[0] in allowed_roots:
                return True
            if relative in GENERATED_SOURCE_FILES:
                return stat.S_ISREG(actual[relative].st_mode)
            if (
                len(parts) in (3, 4)
                and parts[0] == "Packages"
                and parts[2] == ".swiftpm"
                and (len(parts) == 3 or parts[3] == "xcode")
                and stat.S_ISDIR(actual[relative].st_mode)
            ):
                package = parts[1]
                return (
                    f"Packages/{package}" in members
                    and members[f"Packages/{package}"].isdir()
                    and f"Packages/{package}/Package.swift" in members
                )
            return False

        for relative in extras:
            require(
                is_generated_addition(relative),
                f"source snapshot has non-generated addition: {relative}",
            )
        for name, member in members.items():
            metadata = actual.get(name)
            require(metadata is not None, f"source snapshot is missing archive member: {name}")
            path = snapshot_path / name
            require(
                (stat.S_ISDIR(metadata.st_mode) and member.isdir())
                or (stat.S_ISREG(metadata.st_mode) and member.isreg())
                or (stat.S_ISLNK(metadata.st_mode) and member.issym()),
                f"source snapshot member kind differs: {name}",
            )
            require(
                stat.S_IMODE(metadata.st_mode) & 0o111 == member.mode & 0o111,
                f"source snapshot executable mode differs: {name}",
            )
            if member.isreg():
                require(metadata.st_size == member.size, f"source snapshot size differs: {name}")
                stream = archive.extractfile(member)
                require(stream is not None, f"could not read source archive member: {name}")
                with stream, path.open("rb") as snapshot_stream:
                    while True:
                        archived = stream.read(1024 * 1024)
                        snapshotted = snapshot_stream.read(1024 * 1024)
                        require(archived == snapshotted, f"source snapshot bytes differ: {name}")
                        if not archived:
                            break
            elif member.issym():
                require(os.readlink(path) == member.linkname, f"source snapshot symlink differs: {name}")


def hash_source_archive_tree(path: Path) -> str:
    """Hash the logical tree of an uncompressed Git source archive without extracting it."""

    with _open_source_archive(path) as archive:
        members = _source_archive_members(archive)

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
