from __future__ import annotations

from .context import (
    PARTIAL_AUDIT_EXIT_STATUS,
    REPOSITORY_ROOT,
    Path,
    argparse,
    sys,
)
from .core import AuditError, require
from .pack import validate_pack

def canonical_directory_argument(path: Path, label: str) -> Path:
    candidate = path if path.is_absolute() else Path.cwd() / path
    try:
        resolved = candidate.resolve(strict=True)
    except OSError as error:
        raise AuditError(f"could not resolve {label} {path}: {error}") from error
    require(
        resolved == candidate,
        f"{label} must name a real canonical directory without symlink components: {path}",
    )
    return candidate


def parse_arguments() -> argparse.Namespace:
    repository_root = REPOSITORY_ROOT
    default_pack = (
        repository_root
        / "docs"
        / "performance-evidence"
        / "editor-find-f2"
        / "2026-08-08-c871ddf5"
    )
    parser = argparse.ArgumentParser(
        description="Audit retained compact F2 performance evidence without overstating its scope."
    )
    parser.add_argument(
        "pack",
        nargs="?",
        type=Path,
        default=default_pack,
        help=f"evidence-pack directory (default: {default_pack})",
    )
    parser.add_argument(
        "--artifact-root",
        type=Path,
        help="optional root containing every full artifactRootPath named by run provenance",
    )
    parser.add_argument(
        "--allow-partial",
        action="store_true",
        help=(
            "return zero after a compact-only PARTIAL/OPEN audit; without this flag "
            f"a valid compact-only audit exits {PARTIAL_AUDIT_EXIT_STATUS}"
        ),
    )
    arguments = parser.parse_args()
    if arguments.allow_partial and arguments.artifact_root is not None:
        parser.error("--allow-partial cannot be combined with --artifact-root")
    try:
        arguments.pack = canonical_directory_argument(arguments.pack, "evidence pack")
        if arguments.artifact_root is not None:
            arguments.artifact_root = canonical_directory_argument(
                arguments.artifact_root,
                "full artifact root",
            )
    except AuditError as error:
        parser.error(str(error))
    return arguments


def main() -> None:
    arguments = parse_arguments()
    try:
        validate_pack(arguments.pack, arguments.artifact_root)
    except (AuditError, OSError, ValueError) as error:
        print(f"F2 RETAINED EVIDENCE AUDIT FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
    if arguments.artifact_root is None and not arguments.allow_partial:
        print(
            "F2 RETAINED EVIDENCE AUDIT OPEN: compact validation is partial; "
            "pass --allow-partial to accept that limited scope or provide --artifact-root",
            file=sys.stderr,
        )
        raise SystemExit(PARTIAL_AUDIT_EXIT_STATUS)
