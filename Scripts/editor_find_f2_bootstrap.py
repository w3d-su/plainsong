"""Isolated, hash-pinned loader for maintained F2 evidence tooling."""

from __future__ import annotations

import hashlib
import importlib
import importlib.util
import os
import stat
import subprocess
import sys
from pathlib import Path, PurePosixPath


PACKAGE = "editor_find_f2_evidence"
EXPECTED_MODULES = {
    "__init__.py": "cc0d37361990dd37588ed12435dacf358536a8ce736c0b1ab959ee33ac07a46a",
    "artifact_hash.py": "bfdc207fb9d0f6f2df76db5e289aead16aa9239748cdb72fffc578db833492ef",
    "builder.py": "791af18beab958a0b310d8dc0374f10865ca3a15273e03afb25bf00a1d814e5c",
    "builder_cli.py": "1805d741ede66b04c809e783e8307965994391dc10c935f7a0ea2b9e5c050748",
    "builder_inputs.py": "aa56cba08fc90b8c629a8b53441688a81bca14d41c55525417457cff8ea55650",
    "builder_io.py": "e6e656c2aa261bfa6a28d3c2cf7640d12a2d02b717695ed49faa3d2ef694b67a",
    "builder_summary.py": "743e5618a5b561b60c8af9c8ef67d166bf11a8a712e66b15054f0c9462b5967e",
    "cli.py": "a8e4baaa85cabaf12376de0696a00ab24e110edb209d15ee3e32ec322278a914",
    "errors.py": "754eacf487bfa61ab55f2703faad6698433d80310bd03b83798b2515aa6882f4",
    "logs.py": "bb9823aed728b948b78c4cf8a96a7c256f3fa433ffcf3a43250fa6843cfd6b8c",
    "monitor.py": "9d518622dda53ba61a4a3f20ae4b367758e526f89db899ad271d52ec890d3d6c",
    "pack.py": "1a2eb861fecdc34b664d3c79034c69a4ee71fdef4f2cf53657b95c58c35cd505",
    "schema.py": "ccaa6b2e23fa34fbd086957b50f521a9796e9fd1246d720bcc226bbc9961aad8",
    "strict_io.py": "2cf5df2332bead720f1dd6b37331d9d464e67382d1e0dd1fc34d2073bf98889b",
}
EXPECTED_SUPPORT_FILES = {
    "editor-find-f2-evidence/schema.json": "99e9a0163e80c0e69d993f2b8e8572271a7eaeb20e2dea89951ae0a83acb313a",
}


def _reject_acl_allows(path: Path) -> bool:
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


def _owner_controlled(path: Path, expected_kind: str) -> os.stat_result:
    metadata = path.lstat()
    expected = (
        stat.S_ISREG(metadata.st_mode)
        if expected_kind == "file"
        else stat.S_ISDIR(metadata.st_mode)
    )
    if (
        not expected
        or stat.S_ISLNK(metadata.st_mode)
        or metadata.st_uid != os.getuid()
        or metadata.st_mode & 0o022
        or not _reject_acl_allows(path)
    ):
        raise SystemExit(f"F2 tooling path is not owner-controlled: {path}")
    return metadata


def _validate_package(script_directory: Path) -> Path:
    package_root = script_directory / PACKAGE
    _owner_controlled(package_root, "directory")
    actual_files: set[str] = set()
    pending = [(package_root, PurePosixPath())]
    while pending:
        directory, prefix = pending.pop()
        with os.scandir(directory) as entries:
            for entry in entries:
                relative = (prefix / entry.name).as_posix()
                path = Path(entry.path)
                metadata = entry.stat(follow_symlinks=False)
                if stat.S_ISDIR(metadata.st_mode):
                    _owner_controlled(path, "directory")
                    pending.append((path, prefix / entry.name))
                elif stat.S_ISREG(metadata.st_mode):
                    _owner_controlled(path, "file")
                    actual_files.add(relative)
                else:
                    raise SystemExit(f"unsupported F2 tooling entry: {relative}")
    if actual_files != set(EXPECTED_MODULES):
        raise SystemExit("F2 tooling module inventory differs from the pinned set")
    for relative, expected_digest in EXPECTED_MODULES.items():
        pure = PurePosixPath(relative)
        if pure.is_absolute() or ".." in pure.parts:
            raise SystemExit("invalid pinned F2 module path")
        path = package_root.joinpath(*pure.parts)
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest != expected_digest:
            raise SystemExit(f"F2 tooling module hash mismatch: {relative}")
    for relative, expected_digest in EXPECTED_SUPPORT_FILES.items():
        pure = PurePosixPath(relative)
        if pure.is_absolute() or ".." in pure.parts:
            raise SystemExit("invalid pinned F2 support path")
        path = script_directory.joinpath(*pure.parts)
        _owner_controlled(path.parent, "directory")
        _owner_controlled(path, "file")
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest != expected_digest:
            raise SystemExit(f"F2 tooling support hash mismatch: {relative}")
    return package_root


def load_main(wrapper_path: str, module_name: str):
    """Validate the isolated trust root, then return a pinned module's main."""

    if not sys.flags.isolated:
        raise SystemExit(
            "F2 tooling entry point requires isolated Python; use /usr/bin/python3 -I"
        )
    sys.dont_write_bytecode = True
    wrapper = Path(wrapper_path).absolute()
    _owner_controlled(wrapper, "file")
    script_directory = wrapper.parent
    _owner_controlled(script_directory, "directory")
    if wrapper.resolve(strict=True) != wrapper or script_directory.resolve(strict=True) != script_directory:
        raise SystemExit("F2 tooling entry point and directory must be canonical")
    package_root = _validate_package(script_directory)
    package_spec = importlib.util.spec_from_file_location(
        PACKAGE,
        package_root / "__init__.py",
        submodule_search_locations=[str(package_root)],
    )
    if package_spec is None or package_spec.loader is None:
        raise SystemExit("could not create the pinned F2 tooling package")
    package = importlib.util.module_from_spec(package_spec)
    sys.modules[PACKAGE] = package
    package_spec.loader.exec_module(package)
    return importlib.import_module(f"{PACKAGE}.{module_name}").main
