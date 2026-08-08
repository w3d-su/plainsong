"""Read an xcresult summary from a private copy of retained evidence."""

from __future__ import annotations

import os
import pwd
import subprocess
import tempfile
from pathlib import Path

from .artifact_hash import hash_artifact
from .builder_io import DestinationRegistry, copy_tree
from .errors import AuditError, require
from .schema import load_json_bytes


def _environment() -> dict[str, str]:
    account = pwd.getpwuid(os.getuid())
    return {
        "HOME": account.pw_dir,
        "LANG": "C",
        "LC_ALL": "C",
        "LOGNAME": account.pw_name,
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "TMPDIR": "/private/tmp",
        "USER": account.pw_name,
    }


def xcresult_summary(source: Path) -> bytes:
    """Return strict JSON summary bytes without mutating the retained bundle."""

    source_digest = hash_artifact(source)
    with tempfile.TemporaryDirectory(prefix="plainsong-f2-pack-summary.", dir="/private/tmp") as temporary:
        root = Path(temporary)
        copy = root / "Result.xcresult"
        copy_tree(source, copy, DestinationRegistry(root))
        require(hash_artifact(copy) == source_digest, "private xcresult copy differs")
        try:
            completed = subprocess.run(
                [
                    "/usr/bin/xcrun", "xcresulttool", "get", "test-results",
                    "summary", "--compact", "--path", str(copy),
                ],
                check=False,
                capture_output=True,
                env=_environment(),
                timeout=60,
            )
        except subprocess.TimeoutExpired as error:
            raise AuditError("xcresulttool summary timed out after 60 seconds") from error
        require(
            completed.returncode == 0,
            "xcresulttool summary failed: "
            + completed.stderr.decode("utf-8", errors="replace").strip(),
        )
        load_json_bytes(completed.stdout, "xcresulttool summary")
    require(hash_artifact(source) == source_digest, "retained inspection xcresult changed")
    return completed.stdout
