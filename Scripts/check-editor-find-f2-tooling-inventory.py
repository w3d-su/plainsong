#!/usr/bin/python3 -I

"""Verify the maintained F2 operator-tooling inventory and authority boundary."""

from __future__ import annotations

import hashlib
import os
import re
import stat
import subprocess
import sys
from pathlib import Path, PurePosixPath


ROOT_FILES = {
    "build-editor-find-f2-performance-gate.sh",
    "build-editor-find-f2-retained-pack.py",
    "capture-editor-find-f2-authoritative-run.sh",
    "capture-editor-find-f2-log.py",
    "check-editor-find-f2-retained-evidence.py",
    "check-editor-find-f2-tooling-inventory.py",
    "check-editor-find-f2-warning-phase.py",
    "editor_find_f2_bootstrap.py",
    "hash-editor-find-f2-artifact.py",
    "run-editor-find-f2-performance-gate.sh",
}
DIRECTORIES = {
    "editor-find-f2-capture": {"common.sh", "monitor.sh", "processes.sh", "run.sh"},
    "editor-find-f2-evidence": {"schema.json", "schema_check.py"},
    "editor-find-f2-runner": {
        "build-integrity.sh",
        "capture-integrity.sh",
        "inspection.sh",
        "setup.sh",
    },
    "editor_find_f2_evidence": {
        "__init__.py",
        "artifact_hash.py",
        "builder.py",
        "builder_cli.py",
        "builder_inputs.py",
        "builder_io.py",
        "builder_summary.py",
        "cli.py",
        "errors.py",
        "full_artifacts.py",
        "logs.py",
        "monitor.py",
        "pack.py",
        "schema.py",
        "strict_io.py",
    },
}
LINE = re.compile(r"([0-9a-f]{64})  (Scripts/[A-Za-z0-9_./-]+)")


def _acl_is_restricted(path: Path) -> bool:
    result = subprocess.run(
        ["/bin/ls", "-lde", str(path)],
        check=False,
        capture_output=True,
        text=True,
        env={"LANG": "C", "LC_ALL": "C", "PATH": "/usr/bin:/bin"},
    )
    return result.returncode == 0 and all(
        " allow " not in line for line in result.stdout.splitlines()[1:]
    )


def _owner_controlled(path: Path, directory: bool = False) -> os.stat_result:
    metadata = path.lstat()
    expected = stat.S_ISDIR(metadata.st_mode) if directory else stat.S_ISREG(metadata.st_mode)
    if (
        not expected
        or stat.S_ISLNK(metadata.st_mode)
        or metadata.st_uid != os.getuid()
        or metadata.st_mode & 0o022
        or not _acl_is_restricted(path)
    ):
        raise SystemExit(f"F2 TOOLING INVENTORY FAIL uncontrolled path: {path}")
    return metadata


def _read_owned(path: Path) -> bytes:
    metadata = _owner_controlled(path)
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(descriptor, "rb") as stream:
        opened = os.fstat(stream.fileno())
        if (opened.st_dev, opened.st_ino) != (metadata.st_dev, metadata.st_ino):
            raise SystemExit(f"F2 TOOLING INVENTORY FAIL path changed while opening: {path}")
        return stream.read()


def _sha256(path: Path) -> str:
    return hashlib.sha256(_read_owned(path)).hexdigest()


def _expected() -> set[str]:
    names = {f"Scripts/{name}" for name in ROOT_FILES}
    for directory, leaves in DIRECTORIES.items():
        names.update(f"Scripts/{directory}/{leaf}" for leaf in leaves)
    return names


def main() -> None:
    if not sys.flags.isolated:
        raise SystemExit("F2 TOOLING INVENTORY FAIL isolated Python is required")
    script = Path(__file__).absolute()
    scripts = script.parent
    repository = scripts.parent
    if (
        script.resolve(strict=True) != script
        or scripts.resolve(strict=True) != scripts
        or repository.resolve(strict=True) != repository
    ):
        raise SystemExit("F2 TOOLING INVENTORY FAIL non-canonical checkout")
    _owner_controlled(script)
    _owner_controlled(scripts, directory=True)
    inventory = scripts / "editor-find-f2-tooling.sha256"
    _owner_controlled(inventory)
    try:
        text = _read_owned(inventory).decode("ascii", errors="strict")
    except UnicodeDecodeError as error:
        raise SystemExit(f"F2 TOOLING INVENTORY FAIL non-ASCII inventory: {error}")
    if not text.endswith("\n"):
        raise SystemExit("F2 TOOLING INVENTORY FAIL inventory must end with LF")
    records: dict[str, str] = {}
    for number, line in enumerate(text.splitlines(), start=1):
        match = LINE.fullmatch(line)
        if match is None:
            raise SystemExit(f"F2 TOOLING INVENTORY FAIL invalid line {number}")
        digest, relative = match.groups()
        pure = PurePosixPath(relative)
        if pure.is_absolute() or ".." in pure.parts or relative in records:
            raise SystemExit(f"F2 TOOLING INVENTORY FAIL unsafe/duplicate line {number}")
        records[relative] = digest
    if list(records) != sorted(records) or set(records) != _expected():
        raise SystemExit("F2 TOOLING INVENTORY FAIL path set/order differs")
    for directory in DIRECTORIES:
        _owner_controlled(scripts / directory, directory=True)
    for relative, expected in records.items():
        actual = _sha256(repository / relative)
        if actual != expected:
            raise SystemExit(f"F2 TOOLING INVENTORY FAIL hash mismatch: {relative}")
    print(f"F2 TOOLING INVENTORY PASS files={len(records)}")


if __name__ == "__main__":
    main()
