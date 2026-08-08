#!/usr/bin/python3 -I

"""Fail-closed entry point for the modular Phase 3 F2 tooling."""

import sys


# Direct execution supplies -I in the shebang. Explicit interpreter callers
# must do the same; reject before this script loads any non-builtin module.
if not sys.flags.isolated:
    raise SystemExit(
        "F2 tooling entry point requires isolated Python; use /usr/bin/python3 -I"
    )

import hashlib
import importlib
import importlib.util
import os
import stat
import subprocess
from pathlib import Path, PurePosixPath


EXPECTED_MODULES = {
    "editor_find_f2_assembler/__init__.py": "5242f346d6da7a039e789e2f27233a2656668238bbc1744d87242e2b0bb17a92",
    "editor_find_f2_assembler/context.py": "08f59ff03d146c48d44e959b602b218d7aacfc45d98e6da40faf2fdc3c1b427a",
    "editor_find_f2_assembler/io.py": "0e102fc3cde84cbd27b04a67771e10ce75244e4e79d165d70860849381822cac",
    "editor_find_f2_assembler/run.py": "bdb049369eb17160c5b10d3043f5fd8c461f3319482548e26f29b163c5b706c3",
    "editor_find_f2_assembler/cli.py": "55daa60a4dad0b6046ed3fa667070b7928fd72c836f040ca741cd2b52b481712",
}


def rejects_acl_allows(path: Path) -> bool:
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


def bootstrap():
    sys.dont_write_bytecode = True
    wrapper = Path(__file__).absolute()
    wrapper_metadata = wrapper.lstat()
    if (
        wrapper.is_symlink()
        or not stat.S_ISREG(wrapper_metadata.st_mode)
        or wrapper_metadata.st_uid != os.getuid()
        or wrapper_metadata.st_mode & 0o022
        or not rejects_acl_allows(wrapper)
    ):
        raise SystemExit("F2 tooling entry point must be a regular non-symlink")
    script_directory = wrapper.parent
    script_metadata = script_directory.lstat()
    if (
        script_directory.resolve(strict=True) != script_directory
        or not stat.S_ISDIR(script_metadata.st_mode)
        or script_metadata.st_uid != os.getuid()
        or script_metadata.st_mode & 0o022
        or not rejects_acl_allows(script_directory)
    ):
        raise SystemExit("F2 tooling directory must be canonical")
    expected_root = script_directory / "editor_find_f2_assembler"
    root_metadata = expected_root.lstat()
    if (
        expected_root.is_symlink()
        or not stat.S_ISDIR(root_metadata.st_mode)
        or root_metadata.st_uid != os.getuid()
        or root_metadata.st_mode & 0o022
        or not rejects_acl_allows(expected_root)
    ):
        raise SystemExit("F2 tooling package must be an owner-controlled directory")
    actual_names = {
        path.relative_to(script_directory).as_posix()
        for path in expected_root.rglob("*")
        if path.is_file() or path.is_symlink()
    }
    if actual_names != set(EXPECTED_MODULES):
        raise SystemExit("F2 tooling module inventory differs from the pinned set")
    for relative, expected_digest in EXPECTED_MODULES.items():
        pure = PurePosixPath(relative)
        if pure.is_absolute() or ".." in pure.parts:
            raise SystemExit("invalid pinned F2 module path")
        path = script_directory.joinpath(*pure.parts)
        metadata = path.lstat()
        if not stat.S_ISREG(metadata.st_mode) or path.is_symlink():
            raise SystemExit(f"F2 tooling module is not a regular file: {relative}")
        if metadata.st_uid != os.getuid() or metadata.st_mode & 0o022:
            raise SystemExit(f"F2 tooling module is not owner-controlled: {relative}")
        if not rejects_acl_allows(path):
            raise SystemExit(f"F2 tooling module has an ACL allow entry: {relative}")
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest != expected_digest:
            raise SystemExit(f"F2 tooling module hash mismatch: {relative}")
    package_name = "editor_find_f2_assembler"
    package_spec = importlib.util.spec_from_file_location(
        package_name,
        expected_root / "__init__.py",
        submodule_search_locations=[str(expected_root)],
    )
    if package_spec is None or package_spec.loader is None:
        raise SystemExit("could not create the pinned F2 tooling package")
    package = importlib.util.module_from_spec(package_spec)
    sys.modules[package_name] = package
    package_spec.loader.exec_module(package)
    return importlib.import_module(f"{package_name}.cli").main


main = bootstrap()


if __name__ == "__main__":
    main()
