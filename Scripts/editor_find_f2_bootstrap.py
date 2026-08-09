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
    "artifact_hash.py": "e93a066d9edc36fbaf4780cd0573b2fe08f953b02e6aec7645e580e99f0e9623",
    "builder.py": "1dd7869d18bd0e82f0021870b30fb4a98a0aa37b168378a912595b1b2032dc3b",
    "builder_cli.py": "1805d741ede66b04c809e783e8307965994391dc10c935f7a0ea2b9e5c050748",
    "builder_inputs.py": "e97f2f351a464b0f5c280e47fe1421ac2489e8e299527e26af3617fdb4b1b499",
    "builder_io.py": "e6e656c2aa261bfa6a28d3c2cf7640d12a2d02b717695ed49faa3d2ef694b67a",
    "builder_summary.py": "743e5618a5b561b60c8af9c8ef67d166bf11a8a712e66b15054f0c9462b5967e",
    "cli.py": "060645c7c5f8611240a2b4dd409f2ac43ea134f3767446822779c8cdf1af7bd5",
    "errors.py": "754eacf487bfa61ab55f2703faad6698433d80310bd03b83798b2515aa6882f4",
    "full_artifacts.py": "ad25831c66eba3f35d33321d15a7bc9fd56b1e0675f5deda1c196c9988251cdb",
    "logs.py": "bb9823aed728b948b78c4cf8a96a7c256f3fa433ffcf3a43250fa6843cfd6b8c",
    "monitor.py": "9d518622dda53ba61a4a3f20ae4b367758e526f89db899ad271d52ec890d3d6c",
    "pack.py": "c6c23902567677fd47b67931b7a8e319ff69d4a8983c89a90aa7b95d1fb615ca",
    "schema.py": "076a49e6684f85a86dc657f4b8ed16d15c2beb506118bfe156f1dc8ea8fce484",
    "strict_io.py": "772e9b7d2ac049a6a256a43d7c586df23e1e7bcfa3de61a3e98c0838ce8c6195",
}
EXPECTED_SUPPORT_FILES = {
    "editor-find-f2-evidence/schema.json": "03f0f05762775e0e1f0cd9f807ba61de269a434f49070a65f1688fcb8a03b4e3",
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
