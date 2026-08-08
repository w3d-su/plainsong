#!/usr/bin/python3 -I

"""Isolated entry point for the maintained F2 retained-evidence builder."""

from __future__ import annotations

import hashlib
import importlib.util
import os
import stat
import subprocess
import sys
from pathlib import Path


EXPECTED_BOOTSTRAP_SHA256 = "665bf66c400e4a9193e7090b76962a4e490795946f219a7e239458383b652c8b"


def _load_bootstrap():
    if not sys.flags.isolated:
        raise SystemExit(
            "F2 tooling entry point requires isolated Python; use /usr/bin/python3 -I"
        )
    wrapper = Path(__file__).absolute()
    if wrapper.resolve(strict=True) != wrapper:
        raise SystemExit("F2 tooling entry point must be canonical")
    script_directory = wrapper.parent
    bootstrap_path = script_directory / "editor_find_f2_bootstrap.py"
    for path, expected_directory in (
        (wrapper, False),
        (script_directory, True),
        (bootstrap_path, False),
    ):
        metadata = path.lstat()
        expected_kind = (
            stat.S_ISDIR(metadata.st_mode)
            if expected_directory
            else stat.S_ISREG(metadata.st_mode)
        )
        acl = subprocess.run(
            ["/bin/ls", "-lde", str(path)],
            check=False,
            capture_output=True,
            text=True,
            env={"LANG": "C", "LC_ALL": "C", "PATH": "/usr/bin:/bin"},
        )
        if (
            not expected_kind
            or stat.S_ISLNK(metadata.st_mode)
            or metadata.st_uid != os.getuid()
            or metadata.st_mode & 0o022
            or acl.returncode != 0
            or any(" allow " in line for line in acl.stdout.splitlines()[1:])
        ):
            raise SystemExit(f"F2 tooling path is not owner-controlled: {path}")
    if hashlib.sha256(bootstrap_path.read_bytes()).hexdigest() != EXPECTED_BOOTSTRAP_SHA256:
        raise SystemExit("F2 tooling bootstrap hash mismatch")
    spec = importlib.util.spec_from_file_location("editor_find_f2_bootstrap", bootstrap_path)
    if spec is None or spec.loader is None:
        raise SystemExit("could not create the F2 tooling bootstrap")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


main = _load_bootstrap().load_main(__file__, "builder_cli")


if __name__ == "__main__":
    main()
