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
    "editor_find_f2_retained/__init__.py": "37a23d9471db32363988904be6ed61ab96e87db11844df68e4a7b05dcc653eda",
    "editor_find_f2_retained/context.py": "3fbcc5629d6a3ce31a91a22219a39a2ea0c1b169317a8a035115879b0d4d4105",
    "editor_find_f2_retained/core.py": "ce1bc7e8388679ab53e6e58015def8d5bd06606b95a5f54c8135c69917f0873e",
    "editor_find_f2_retained/boundary.py": "0c8d6a5e08ec6e9eac20a6b36c78105f120df9798c7f3cd33d45a5df4a87b328",
    "editor_find_f2_retained/competition.py": "9cd1d9bac085a2f5472b7c3f460843d87b895280045f79663bb5af896e176391",
    "editor_find_f2_retained/logs.py": "0af03d16b11da343bc3b6e7a9fd6e035558b066505f922d9e0368b6ab9490b49",
    "editor_find_f2_retained/provenance.py": "3789f7ef85c14fa610399b074efd11229eb75a809fc63fda28ef5acc01681e87",
    "editor_find_f2_retained/artifacts.py": "cdcd7507c08443cb13d1441d0621c2ef8d88eb6664ba3ab84ec390a99ab1bb5a",
    "editor_find_f2_retained/trusted.py": "953844995905632949146b3f74cd8e959f4666ac2b5d7b7d5e4c079eb0717244",
    "editor_find_f2_retained/full_artifacts.py": "7c9d35b613e1472041459a977296f863349ea9318047f2735808bb15434eb250",
    "editor_find_f2_retained/run.py": "9c5c66474763b244e44a117e6af8e3b9c8c0f96b342ff518511d34e9d94d928d",
    "editor_find_f2_retained/pack.py": "7a41482878bfb2fc22cf618421618a025845a9081108d488bfc1e6c080ae9bd7",
    "editor_find_f2_retained/cli.py": "edb42e0f05a0d451c5fc25682f59db5d89e2d604242a3299e42ab7aa8ff2dea8",
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
    expected_root = script_directory / "editor_find_f2_retained"
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
    package_name = "editor_find_f2_retained"
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
