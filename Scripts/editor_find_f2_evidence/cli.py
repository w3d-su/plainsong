"""Command-line surface for the F2 retained-evidence audit."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from .errors import AuditError
from .pack import validate_pack

PARTIAL_EXIT_STATUS = 3


def _arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Audit retained F2 evidence without overstating compact evidence.")
    parser.add_argument("pack", type=Path)
    parser.add_argument("--artifact-root", type=Path)
    parser.add_argument("--allow-partial", action="store_true")
    parser.add_argument("--expected-inventory-sha256")
    arguments = parser.parse_args()
    if arguments.allow_partial and arguments.artifact_root is not None:
        parser.error("--allow-partial cannot be combined with --artifact-root")
    return arguments


def main() -> None:
    arguments = _arguments()
    try:
        runs = validate_pack(
            arguments.pack,
            arguments.artifact_root,
            arguments.expected_inventory_sha256,
        )
    except (AuditError, OSError, ValueError) as error:
        print(f"F2 RETAINED EVIDENCE AUDIT FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
    print(f"F2 RETAINED EVIDENCE {'PASS' if arguments.artifact_root else 'PARTIAL'} runs={len(runs)}")
    print("F2 OPEN full-keystroke-to-screen")
    print("F2 OPEN F8-highlight-apply-clear")
    print("F2 OPEN F9")
    print("F2 OPEN combined-tip")
    print("F2 OPEN independent-durable-retention")
    if arguments.artifact_root is None and not arguments.allow_partial:
        print("F2 RETAINED EVIDENCE AUDIT OPEN: full artifacts were not rehashed", file=sys.stderr)
        raise SystemExit(PARTIAL_EXIT_STATUS)
