"""Parse and bind the six authoritative capture prefixes."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path, PurePosixPath

from .artifact_hash import hash_artifact, hash_source_archive_tree
from .builder_io import canonical_prefix, canonical_source, reject_tree_symlinks
from .errors import require
from .full_artifacts import BUILD_KEYS
from .pack import EVIDENCE_KEYS
from .schema import EvidenceSchema
from .strict_io import (
    SHA256,
    parse_key_values,
    sha256_file,
    validate_digest,
    xctestrun_relative_path,
)

SOURCE_SUFFIXES = {
    "preflight": "preflight.txt",
    "preflightDigest": "preflight.txt.sha256",
    "monitorLog": "competition-monitor.log",
    "monitorLogDigest": "competition-monitor.log.sha256",
    "monitorSamples": "competition-monitor.samples.txt",
    "monitorSamplesDigest": "competition-monitor.samples.txt.sha256",
    "monitorStatus": "competition-monitor.status.txt",
    "monitorStatusDigest": "competition-monitor.status.txt.sha256",
    "rawLog": "log",
    "rawLogDigest": "log.sha256",
    "warningCheck": "warning-check.txt",
    "warningCheckDigest": "warning-check.txt.sha256",
    "evidenceManifest": "evidence-manifest.txt",
    "outerLog": "outer.log",
    "outerLogDigest": "outer.log.sha256",
    "outerStatus": "outer.status.txt",
    "postflight": "postflight.txt",
    "postflightDigest": "postflight.txt.sha256",
}


@dataclass(frozen=True)
class FullArtifactInput:
    path: Path
    kind: str
    hash_mode: str
    expected_sha256: str


@dataclass(frozen=True)
class RunInput:
    run_id: str
    configuration: str
    prefix: Path
    compact_files: dict[str, Path]
    inspection_xcresult: Path
    full_artifacts: dict[str, FullArtifactInput]


def _prefix_path(prefix: Path, suffix: str, kind: str = "file") -> Path:
    return canonical_source(Path(f"{prefix}.{suffix}"), kind, f"{prefix.name}.{suffix}")


def _absolute_manifest_path(value: str, kind: str, label: str) -> Path:
    require(PurePosixPath(value).is_absolute(), f"{label} must be absolute")
    return canonical_source(Path(value), kind, label)


def _require_hash(value: str, label: str) -> str:
    require(SHA256.fullmatch(value) is not None, f"{label} is not SHA-256")
    return value


def _validate_compact_digests(paths: dict[str, Path], label: str) -> None:
    for data_key, digest_key in (
        ("preflight", "preflightDigest"),
        ("monitorLog", "monitorLogDigest"),
        ("monitorSamples", "monitorSamplesDigest"),
        ("monitorStatus", "monitorStatusDigest"),
        ("rawLog", "rawLogDigest"),
        ("warningCheck", "warningCheckDigest"),
        ("outerLog", "outerLogDigest"),
        ("postflight", "postflightDigest"),
    ):
        validate_digest(paths[data_key], paths[digest_key], f"{label} {data_key}")


def load_run_input(run_id: str, prefix_value: Path, schema: EvidenceSchema) -> RunInput:
    prefix = canonical_prefix(prefix_value, f"{run_id} prefix")
    configuration = "Debug" if run_id.startswith("debug-") else "Release"
    compact = {
        key: _prefix_path(prefix, suffix)
        for key, suffix in SOURCE_SUFFIXES.items()
    }
    _validate_compact_digests(compact, run_id)
    evidence = parse_key_values(compact["evidenceManifest"], EVIDENCE_KEYS, f"{run_id} evidence manifest")
    require(
        evidence["format"] == "1"
        and evidence["source_commit"] == schema.source_commit
        and evidence["configuration"] == configuration
        and evidence["status"] == "pass",
        f"{run_id} evidence identity/status differs",
    )
    expected_prefix_paths = {
        "raw_log_path": f"{prefix}.log",
        "warning_check_path": f"{prefix}.warning-check.txt",
        "xcresult_path": f"{prefix}.xcresult",
        "xcresult_inspection_path": f"{prefix}.inspection.xcresult",
    }
    for key, expected in expected_prefix_paths.items():
        require(evidence[key] == expected, f"{run_id} {key} is not bound to its prefix")
    require(
        sha256_file(compact["rawLog"]) == _require_hash(evidence["raw_log_sha256"], f"{run_id} raw log")
        and str(compact["rawLog"].stat().st_size) == evidence["raw_log_bytes"],
        f"{run_id} raw log evidence binding differs",
    )
    require(
        sha256_file(compact["warningCheck"]) == _require_hash(evidence["warning_check_sha256"], f"{run_id} warning")
        and str(compact["warningCheck"].stat().st_size) == evidence["warning_check_bytes"],
        f"{run_id} warning evidence binding differs",
    )

    build_manifest = _absolute_manifest_path(evidence["build_manifest_path"], "file", f"{run_id} build manifest")
    build_sha = _require_hash(evidence["build_manifest_sha256"], f"{run_id} build manifest")
    require(sha256_file(build_manifest) == build_sha, f"{run_id} build manifest hash differs")
    build = parse_key_values(build_manifest, BUILD_KEYS, f"{run_id} build manifest")
    require(
        build["format"] == "5"
        and build["source_commit"] == schema.source_commit
        and build["configuration"] == configuration
        and build["budget_mode"] == "local-hard",
        f"{run_id} build identity/budget differs",
    )
    source_archive = _absolute_manifest_path(build["source_archive_path"], "file", f"{run_id} source archive")
    require(
        schema.source_archive_sha256 is not None
        and schema.source_tree_sha256 is not None
        and build["source_archive_sha256"] == schema.source_archive_sha256
        and build["source_tree_sha256"] == schema.source_tree_sha256
        and sha256_file(source_archive) == schema.source_archive_sha256,
        f"{run_id} source archive/tree differs from the external anchor",
    )
    require(
        hash_source_archive_tree(source_archive) == schema.source_tree_sha256,
        f"{run_id} reconstructed source archive tree differs",
    )
    source_snapshot = _absolute_manifest_path(build["source_snapshot_path"], "directory", f"{run_id} source snapshot")
    package_input = _absolute_manifest_path(build["package_input_path"], "directory", f"{run_id} package input")
    reject_tree_symlinks(source_snapshot, f"{run_id} source snapshot")
    reject_tree_symlinks(package_input, f"{run_id} package input", exclude_git=True)
    xctestrun_relative = xctestrun_relative_path(
        build["xctestrun_relative_path"],
        f"{run_id} xctestrun relative path",
    )
    frozen_products = _prefix_path(prefix, "products", "directory")
    host = canonical_source(
        frozen_products / "Build" / "Products" / configuration / "Plainsong.app",
        "directory",
        f"{run_id} frozen host",
    )
    xctestrun = canonical_source(frozen_products / xctestrun_relative, "file", f"{run_id} frozen xctestrun")
    xcresult = _prefix_path(prefix, "xcresult", "directory")
    inspection = _prefix_path(prefix, "inspection.xcresult", "directory")
    reject_tree_symlinks(host, f"{run_id} frozen host")
    reject_tree_symlinks(xcresult, f"{run_id} xcresult")
    reject_tree_symlinks(inspection, f"{run_id} inspection xcresult")

    full = {
        "sourceArchive": FullArtifactInput(source_archive, "file", "file-sha256", _require_hash(build["source_archive_sha256"], f"{run_id} source archive")),
        "sourceSnapshot": FullArtifactInput(source_snapshot, "directory", "artifact-sha256", _require_hash(build["build_input_sha256"], f"{run_id} source snapshot")),
        "resolvedPackageInput": FullArtifactInput(package_input, "directory", "resolved-package-input-sha256", _require_hash(build["resolved_package_input_sha256"], f"{run_id} package input")),
        "buildManifest": FullArtifactInput(build_manifest, "file", "file-sha256", build_sha),
        "hostBundle": FullArtifactInput(host, "directory", "artifact-sha256", _require_hash(build["host_bundle_sha256"], f"{run_id} host")),
        "xctestrun": FullArtifactInput(xctestrun, "file", "artifact-sha256", _require_hash(build["xctestrun_sha256"], f"{run_id} xctestrun")),
        "rawLog": FullArtifactInput(compact["rawLog"], "file", "file-sha256", _require_hash(evidence["raw_log_sha256"], f"{run_id} raw log")),
        "xcresult": FullArtifactInput(xcresult, "directory", "artifact-sha256", _require_hash(evidence["xcresult_sha256"], f"{run_id} xcresult")),
        "inspectionXcresult": FullArtifactInput(inspection, "directory", "artifact-sha256", _require_hash(evidence["xcresult_inspection_result_sha256"], f"{run_id} inspection")),
    }
    for name, artifact in full.items():
        digest = (
            sha256_file(artifact.path)
            if artifact.hash_mode == "file-sha256"
            else hash_artifact(artifact.path, artifact.hash_mode == "resolved-package-input-sha256")
        )
        require(digest == artifact.expected_sha256, f"{run_id} {name} source hash differs")
    require(
        evidence["xcresult_inspection_input_sha256"] == evidence["xcresult_sha256"],
        f"{run_id} inspection input was not bound to raw xcresult",
    )
    return RunInput(run_id, configuration, prefix, compact, inspection, full)
