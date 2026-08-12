"""Strict path, inventory, digest, and key-value parsing."""

from __future__ import annotations

import hashlib
import os
import re
import stat
import subprocess
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath

from .errors import AuditError, require

SHA256 = re.compile(r"[0-9a-f]{64}")


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    metadata = path.lstat()
    require(
        stat.S_ISREG(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode),
        f"SHA-256 input is not a regular non-symlink: {path}",
    )
    digest = hashlib.sha256()
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(descriptor, "rb") as handle:
        opened = os.fstat(handle.fileno())
        require(
            stat.S_ISREG(opened.st_mode)
            and (opened.st_dev, opened.st_ino) == (metadata.st_dev, metadata.st_ino),
            f"SHA-256 input changed while opening: {path}",
        )
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def reject_tree_acls(root: Path, label: str) -> None:
    result = subprocess.run(
        ["/usr/bin/find", str(root), "-acl", "-print", "-quit"],
        check=False,
        capture_output=True,
        text=True,
        env={"LANG": "C", "LC_ALL": "C", "PATH": "/usr/bin:/bin"},
    )
    require(result.returncode == 0, f"could not inspect {label} ACLs")
    require(result.stdout == "", f"{label} contains an ACL")


def reject_acl_allows(path: Path, label: str) -> None:
    result = subprocess.run(
        ["/bin/ls", "-lde", str(path)],
        check=False,
        capture_output=True,
        text=True,
        env={"LANG": "C", "LC_ALL": "C", "PATH": "/usr/bin:/bin"},
    )
    require(result.returncode == 0, f"could not inspect {label} ACL")
    require(
        all(" allow " not in line for line in result.stdout.splitlines()[1:]),
        f"{label} has an ACL allow entry",
    )


def owner_controlled_tree(root: Path, label: str) -> None:
    """Reject links, special files, foreign owners, and group/world writers."""

    root_metadata = root.lstat()
    require(
        stat.S_ISDIR(root_metadata.st_mode)
        and not stat.S_ISLNK(root_metadata.st_mode)
        and root_metadata.st_uid == os.getuid()
        and not root_metadata.st_mode & 0o022,
        f"{label} root is not owner-controlled",
    )
    pending = [root]
    while pending:
        directory = pending.pop()
        with os.scandir(directory) as entries:
            for entry in entries:
                metadata = entry.stat(follow_symlinks=False)
                relative = Path(entry.path).relative_to(root).as_posix()
                require(
                    not stat.S_ISLNK(metadata.st_mode),
                    f"{label} symlink is forbidden: {relative}",
                )
                require(
                    metadata.st_uid == os.getuid() and not metadata.st_mode & 0o022,
                    f"{label} entry is not owner-controlled: {relative}",
                )
                if stat.S_ISDIR(metadata.st_mode):
                    pending.append(Path(entry.path))
                else:
                    require(
                        stat.S_ISREG(metadata.st_mode),
                        f"{label} has unsupported entry: {relative}",
                    )
    reject_tree_acls(root, label)


def safe_relative_path(value: object, label: str) -> str:
    require(isinstance(value, str) and value != "", f"{label} must be a path string")
    require("\\" not in value and "\x00" not in value, f"{label} is not POSIX-safe")
    path = PurePosixPath(value)
    require(not path.is_absolute(), f"{label} must be relative")
    require(all(part not in ("", ".", "..") for part in path.parts), f"{label} escapes its root")
    require(path.as_posix() == value, f"{label} is not canonical")
    return value


def xctestrun_relative_path(value: object, label: str) -> str:
    relative = safe_relative_path(value, label)
    parts = PurePosixPath(relative).parts
    require(
        len(parts) == 3
        and parts[:2] == ("Build", "Products")
        and parts[2].endswith(".xctestrun")
        and parts[2] != ".xctestrun",
        f"{label} must match Build/Products/*.xctestrun",
    )
    return relative


def paths_overlap(first: str, second: str, case_insensitive: bool = False) -> bool:
    left = PurePosixPath(first)
    right = PurePosixPath(second)
    if case_insensitive:
        left = PurePosixPath(*(part.casefold() for part in left.parts))
        right = PurePosixPath(*(part.casefold() for part in right.parts))
    return left == right or left in right.parents or right in left.parents


def filesystem_paths_overlap(first: Path, second: Path) -> bool:
    """Reject identical inodes and resolved ancestor/descendant aliases."""

    try:
        if os.path.samefile(first, second):
            return True
    except OSError as error:
        raise AuditError(f"could not compare retained artifact identity: {error}") from error
    left = first.resolve(strict=True)
    right = second.resolve(strict=True)
    return left in right.parents or right in left.parents


def strict_pack_files(root: Path) -> set[str]:
    files: set[str] = set()

    owner_controlled_tree(root, "pack")

    def visit(directory: Path, prefix: PurePosixPath) -> None:
        for entry in sorted(os.scandir(directory), key=lambda item: os.fsencode(item.name)):
            relative = (prefix / entry.name).as_posix()
            metadata = entry.stat(follow_symlinks=False)
            require(not stat.S_ISLNK(metadata.st_mode), f"pack symlink is forbidden: {relative}")
            if stat.S_ISDIR(metadata.st_mode):
                visit(Path(entry.path), prefix / entry.name)
            else:
                require(stat.S_ISREG(metadata.st_mode), f"non-file pack entry: {relative}")
                files.add(relative)

    visit(root, PurePosixPath())
    return files


def validate_inventory(root: Path) -> dict[str, str]:
    inventory_path = root / "SHA256SUMS"
    data = inventory_path.read_bytes()
    try:
        text = data.decode("ascii", errors="strict")
    except UnicodeDecodeError as error:
        raise AuditError(f"SHA256SUMS is not ASCII: {error}") from error
    require(text.endswith("\n"), "SHA256SUMS must end with LF")
    records: dict[str, str] = {}
    folded: set[str] = set()
    pattern = re.compile(r"([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9._/-]*)")
    for number, line in enumerate(text.splitlines(), start=1):
        match = pattern.fullmatch(line)
        require(match is not None, f"invalid SHA256SUMS line {number}")
        digest, relative = match.groups()
        safe_relative_path(relative, f"SHA256SUMS line {number}")
        require(relative != "SHA256SUMS" and relative not in records, "duplicate inventory path")
        require(relative.casefold() not in folded, f"case-colliding inventory path: {relative}")
        records[relative] = digest
        folded.add(relative.casefold())
    require(list(records) == sorted(records), "SHA256SUMS must be bytewise sorted")
    actual = strict_pack_files(root) - {"SHA256SUMS"}
    require(set(records) == actual, "SHA256SUMS is not an exact inventory")
    for relative, expected in records.items():
        require(sha256_file(root / relative) == expected, f"SHA256SUMS mismatch for {relative}")
    return records


def pack_file(root: Path, inventory: dict[str, str], relative: str, label: str) -> Path:
    safe_relative_path(relative, label)
    require(relative in inventory, f"{label} is absent from SHA256SUMS")
    path = root / relative
    require(path.is_file() and not path.is_symlink(), f"{label} is not a regular file")
    return path


def parse_key_values(path: Path, keys: tuple[str, ...], label: str) -> dict[str, str]:
    try:
        text = path.read_bytes().decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise AuditError(f"{label} is not UTF-8: {error}") from error
    require(text.endswith("\n"), f"{label} must end with LF")
    values: dict[str, str] = {}
    order: list[str] = []
    for number, line in enumerate(text.splitlines(), start=1):
        require("=" in line, f"{label} line {number} has no equals sign")
        key, value = line.split("=", 1)
        require(re.fullmatch(r"[a-z0-9_]+", key) is not None, f"invalid {label} key")
        require(key not in values and value != "", f"duplicate/empty {label} key")
        values[key] = value
        order.append(key)
    require(tuple(order) == keys, f"{label} key order differs: {order}")
    return values


def parse_digest(path: Path, label: str) -> tuple[str, int]:
    values = parse_key_values(path, ("sha256", "bytes"), label)
    require(SHA256.fullmatch(values["sha256"]) is not None, f"invalid {label} SHA-256")
    require(re.fullmatch(r"[0-9]+", values["bytes"]) is not None, f"invalid {label} byte count")
    return values["sha256"], int(values["bytes"])


def validate_digest(data_path: Path, digest_path: Path, label: str) -> bytes:
    data = data_path.read_bytes()
    digest, byte_count = parse_digest(digest_path, f"{label} digest")
    require(digest == sha256_bytes(data) and byte_count == len(data), f"{label} digest differs")
    return data


def parse_utc(value: str, label: str, microseconds: bool = False) -> datetime:
    fraction = r"\.[0-9]{6}" if microseconds else r"(?:\.[0-9]{1,6})?"
    require(
        re.fullmatch(rf"[0-9]{{4}}-[0-9]{{2}}-[0-9]{{2}}T[0-9]{{2}}:[0-9]{{2}}:[0-9]{{2}}{fraction}Z", value) is not None,
        f"{label} is not RFC3339 UTC",
    )
    parsed = datetime.fromisoformat(value[:-1] + "+00:00")
    require(parsed.tzinfo == timezone.utc, f"{label} is not UTC")
    return parsed
