"""Command-line interface for the F2 retained-evidence pack builder."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from .builder import build_pack
from .errors import AuditError
from .schema import load_schema


def _arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build a fail-closed F2 compact pack and owner-local full-artifact root."
    )
    parser.add_argument("--pack-root", required=True, type=Path)
    parser.add_argument("--artifact-root", required=True, type=Path)
    parser.add_argument(
        "--run",
        required=True,
        action="append",
        metavar="RUN_ID=ABSOLUTE_PREFIX",
        help="repeat once for each schema run ID, in schema order",
    )
    return parser.parse_args()


def _run_prefixes(values: list[str]) -> dict[str, Path]:
    schema = load_schema()
    records: dict[str, Path] = {}
    for value in values:
        run_id, separator, prefix = value.partition("=")
        if not separator or not prefix:
            raise AuditError(f"invalid --run value: {value!r}")
        if run_id in records:
            raise AuditError(f"duplicate --run ID: {run_id}")
        records[run_id] = Path(prefix)
    if tuple(records) != schema.run_ids:
        raise AuditError(
            "--run values must appear exactly in this order: "
            + ", ".join(schema.run_ids)
        )
    return records


def main() -> None:
    arguments = _arguments()
    try:
        prefixes = _run_prefixes(arguments.run)
        build_pack(arguments.pack_root, arguments.artifact_root, prefixes)
    except (AuditError, OSError, ValueError) as error:
        print(f"F2 RETAINED PACK BUILD FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
    print(f"F2 RETAINED PACK BUILD PASS pack={arguments.pack_root}")
    print(f"F2 FULL ARTIFACT ROOT PASS root={arguments.artifact_root}")
