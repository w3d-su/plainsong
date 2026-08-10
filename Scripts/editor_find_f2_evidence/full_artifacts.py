"""Semantic and content validation for optional full F2 artifact roots."""

from __future__ import annotations

from pathlib import Path, PurePosixPath

from .artifact_hash import hash_artifact, hash_source_archive_tree, validate_source_snapshot
from .errors import require
from .schema import EvidenceSchema, load_json_bytes
from .strict_io import (
    SHA256,
    filesystem_paths_overlap,
    parse_key_values,
    paths_overlap,
    safe_relative_path,
    sha256_file,
    xctestrun_relative_path,
)

BUILD_KEYS = (
    "format", "source_commit", "configuration", "repository_root",
    "source_snapshot_path", "source_archive_path", "source_archive_sha256",
    "source_tree_sha256", "build_input_sha256", "package_input_path",
    "resolved_package_input_sha256", "xcodegen_path", "xcodegen_sha256",
    "destination", "budget_mode", "host_bundle_sha256",
    "xctestrun_relative_path", "xctestrun_sha256",
)
EXPECTED_ARTIFACTS = {
    "sourceArchive": ("file", "file-sha256"),
    "sourceSnapshot": ("directory", "artifact-sha256"),
    "resolvedPackageInput": ("directory", "resolved-package-input-sha256"),
    "buildManifest": ("file", "file-sha256"),
    "hostBundle": ("directory", "artifact-sha256"),
    "xctestrun": ("file", "artifact-sha256"),
    "rawLog": ("file", "file-sha256"),
    "xcresult": ("directory", "artifact-sha256"),
    "inspectionXcresult": ("directory", "artifact-sha256"),
}


def _exact_keys(value: object, keys: set[str], label: str) -> dict:
    require(isinstance(value, dict) and set(value) == keys, f"{label} keys differ")
    return value


def load_provenance(
    provenance_path: Path,
    run_id: str,
    configuration: str,
    schema: EvidenceSchema,
) -> dict:
    provenance = _exact_keys(
        load_json_bytes(provenance_path.read_bytes(), f"{run_id} artifact provenance"),
        {
            "format", "sourceCommit", "configuration", "runId",
            "retainedInPack", "retainedAtArtifactRoot", "verificationScope", "artifacts",
        },
        f"{run_id} artifact provenance",
    )
    require(
        provenance["format"] == 1
        and provenance["sourceCommit"] == schema.source_commit
        and provenance["configuration"] == configuration
        and provenance["runId"] == run_id
        and provenance["retainedInPack"] is False
        and provenance["retainedAtArtifactRoot"] is True
        and provenance["verificationScope"] == "owner-local-full-artifact",
        f"{run_id} provenance identity/scope differs",
    )
    records = provenance["artifacts"]
    require(isinstance(records, dict) and set(records) == set(EXPECTED_ARTIFACTS), f"{run_id} full artifact set differs")
    relatives: dict[str, str] = {}
    for name, (_, hash_mode) in EXPECTED_ARTIFACTS.items():
        record = _exact_keys(
            records[name],
            {"originalPath", "artifactRootPath", "hashMode", "sha256"},
            f"{run_id} {name}",
        )
        require(
            isinstance(record["originalPath"], str)
            and PurePosixPath(record["originalPath"]).is_absolute(),
            f"{run_id} {name} original path differs",
        )
        relatives[name] = safe_relative_path(record["artifactRootPath"], f"{run_id} {name} path")
        require(
            record["hashMode"] == hash_mode
            and isinstance(record["sha256"], str)
            and SHA256.fullmatch(record["sha256"]) is not None,
            f"{run_id} {name} metadata differs",
        )
    names = tuple(relatives)
    for index, name in enumerate(names):
        for other in names[index + 1:]:
            require(
                not paths_overlap(relatives[name], relatives[other], case_insensitive=True),
                f"{run_id} artifact paths overlap: {name}/{other}",
            )
    require(
        schema.source_archive_sha256 is not None
        and records["sourceArchive"]["sha256"] == schema.source_archive_sha256,
        f"{run_id} source archive differs from the external anchor",
    )
    return provenance


def validate_artifacts(
    provenance: dict,
    artifact_root: Path,
    run_id: str,
    configuration: str,
    schema: EvidenceSchema,
    evidence: dict[str, str],
    output_prefix: str,
) -> None:
    records = provenance["artifacts"]
    verified: dict[str, tuple[dict, Path, str]] = {}
    resolved_paths: dict[str, Path] = {}
    artifact_root_resolved = artifact_root.resolve(strict=True)
    for name, (kind, hash_mode) in EXPECTED_ARTIFACTS.items():
        record = records[name]
        relative = safe_relative_path(record["artifactRootPath"], f"{run_id} {name} path")
        path = artifact_root / relative
        resolved = path.resolve(strict=True)
        require(
            resolved.is_relative_to(artifact_root_resolved),
            f"{run_id} {name} escapes artifact root",
        )
        require((path.is_file() if kind == "file" else path.is_dir()) and not path.is_symlink(), f"{run_id} {name} kind differs")
        for other, other_path in resolved_paths.items():
            require(
                not filesystem_paths_overlap(path, other_path),
                f"{run_id} artifact filesystem paths overlap: {name}/{other}",
            )
        resolved_paths[name] = path
        digest = (
            sha256_file(path)
            if hash_mode == "file-sha256"
            else hash_artifact(path, hash_mode == "resolved-package-input-sha256")
        )
        require(digest == record["sha256"], f"{run_id} {name} hash differs")
        verified[name] = (record, path, digest)

    build_record, build_path, build_digest = verified["buildManifest"]
    require(
        build_digest == evidence["build_manifest_sha256"]
        and build_record["originalPath"] == evidence["build_manifest_path"],
        f"{run_id} build manifest evidence binding differs",
    )
    build = parse_key_values(build_path, BUILD_KEYS, f"{run_id} retained build manifest")
    require(
        build["format"] == "5"
        and build["source_commit"] == schema.source_commit
        and build["configuration"] == configuration
        and build["budget_mode"] == "local-hard",
        f"{run_id} retained build identity/budget differs",
    )
    require(
        schema.source_archive_sha256 is not None
        and schema.source_tree_sha256 is not None
        and build["source_archive_sha256"] == schema.source_archive_sha256
        and build["source_tree_sha256"] == schema.source_tree_sha256,
        f"{run_id} source integrity differs from the external anchor",
    )
    require(
        hash_source_archive_tree(verified["sourceArchive"][1]) == schema.source_tree_sha256,
        f"{run_id} reconstructed source archive tree differs",
    )
    validate_source_snapshot(
        verified["sourceArchive"][1],
        verified["sourceSnapshot"][1],
    )
    xctestrun_relative = xctestrun_relative_path(
        build["xctestrun_relative_path"],
        f"{run_id} retained xctestrun relative path",
    )
    expected = {
        "sourceArchive": (build["source_archive_sha256"], build["source_archive_path"]),
        "sourceSnapshot": (build["build_input_sha256"], build["source_snapshot_path"]),
        "resolvedPackageInput": (
            build["resolved_package_input_sha256"],
            build["package_input_path"],
        ),
        "buildManifest": (evidence["build_manifest_sha256"], evidence["build_manifest_path"]),
        "hostBundle": (
            build["host_bundle_sha256"],
            f"{output_prefix}.products/Build/Products/{configuration}/Plainsong.app",
        ),
        "xctestrun": (
            build["xctestrun_sha256"],
            f"{output_prefix}.products/{xctestrun_relative}",
        ),
        "rawLog": (evidence["raw_log_sha256"], evidence["raw_log_path"]),
        "xcresult": (evidence["xcresult_sha256"], evidence["xcresult_path"]),
        "inspectionXcresult": (
            evidence["xcresult_inspection_result_sha256"],
            evidence["xcresult_inspection_path"],
        ),
    }
    for name, (expected_digest, expected_original) in expected.items():
        record, _, digest = verified[name]
        require(
            SHA256.fullmatch(expected_digest) is not None
            and digest == expected_digest
            and record["originalPath"] == expected_original,
            f"{run_id} {name} retained-evidence binding differs",
        )
