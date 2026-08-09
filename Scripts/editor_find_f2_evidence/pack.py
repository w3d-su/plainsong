"""Composition of the compact and optional full-artifact F2 audits."""

from __future__ import annotations

import json
import re
from dataclasses import replace
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath

from .errors import AuditError, require
from .full_artifacts import load_provenance, validate_artifacts
from .logs import WARNING, validate_timings, validate_warning_negative_control, validate_warning_phase
from .monitor import validate_boundary, validate_monitor, validate_outer
from .schema import (
    CURRENT_MANIFEST_FORMAT,
    EvidenceSchema,
    auditor_paths_for_manifest,
    load_json_bytes,
    load_schema,
    tooling_digest,
)
from .strict_io import (
    SHA256,
    pack_file,
    parse_key_values,
    owner_controlled_tree,
    safe_relative_path,
    sha256_bytes,
    sha256_file,
    validate_digest,
    validate_inventory,
)

RUN_FILES = {
    "preflight": "preflight.txt",
    "preflightDigest": "preflight.txt.sha256",
    "monitorLog": "competition-monitor.log",
    "monitorLogDigest": "competition-monitor.log.sha256",
    "monitorSamples": "competition-monitor.samples.txt",
    "monitorSamplesDigest": "competition-monitor.samples.txt.sha256",
    "monitorStatus": "competition-monitor.status.txt",
    "monitorStatusDigest": "competition-monitor.status.txt.sha256",
    "rawLog": "raw.log",
    "rawLogDigest": "raw.log.sha256",
    "warningCheck": "warning-check.txt",
    "warningCheckDigest": "warning-check.txt.sha256",
    "evidenceManifest": "evidence-manifest.txt",
    "outerLog": "outer.log",
    "outerLogDigest": "outer.log.sha256",
    "outerStatus": "outer.status.txt",
    "xcresultSummary": "xcresult-summary.json",
    "fullArtifactProvenance": "full-artifact-provenance.json",
    "postflight": "postflight.txt",
    "postflightDigest": "postflight.txt.sha256",
}
EVIDENCE_KEYS = (
    "format",
    "source_commit",
    "configuration",
    "build_manifest_path",
    "build_manifest_sha256",
    "raw_log_path",
    "raw_log_sha256",
    "raw_log_bytes",
    "xcresult_path",
    "xcresult_sha256",
    "xcresult_inspection_path",
    "xcresult_inspection_input_sha256",
    "xcresult_inspection_result_sha256",
    "warning_check_path",
    "warning_check_sha256",
    "warning_check_bytes",
    "status",
)
def _exact_keys(value: object, keys: set[str], label: str) -> dict:
    require(isinstance(value, dict) and set(value) == keys, f"{label} keys differ")
    return value


def _json_file(path: Path, label: str) -> object:
    return load_json_bytes(path.read_bytes(), label)


def _summary_times(summary: dict, label: str) -> tuple[datetime, datetime]:
    require(summary.get("result") == "Passed", f"{label} summary is not passed")
    for key, expected in (("passedTests", 2), ("failedTests", 0), ("skippedTests", 0), ("totalTestCount", 2)):
        require(summary.get(key) == expected, f"{label} summary {key} differs")
    warnings = summary.get("runtimeWarnings")
    require(isinstance(warnings, list) and len(warnings) == 1, f"{label} summary warning count differs")
    require(warnings[0].get("message") == WARNING, f"{label} summary warning differs")
    start = summary.get("startTime")
    finish = summary.get("finishTime")
    require(isinstance(start, (int, float)) and isinstance(finish, (int, float)), f"{label} summary times missing")
    started = datetime.fromtimestamp(start, timezone.utc)
    finished = datetime.fromtimestamp(finish, timezone.utc)
    require(started <= finished, f"{label} summary chronology differs")
    return started, finished


def _run_path(root: Path, inventory: dict[str, str], directory: str, key: str, label: str) -> Path:
    return pack_file(root, inventory, f"{directory}/{RUN_FILES[key]}", f"{label} {key}")


def _validate_run(
    root: Path,
    inventory: dict[str, str],
    run: dict,
    schema: EvidenceSchema,
    artifact_root: Path | None,
) -> dict[str, object]:
    run = _exact_keys(
        run,
        {"id", "configuration", "directory", "captureToolingSHA256"},
        "run record",
    )
    run_id = run["id"]
    configuration = run["configuration"]
    require(run_id in schema.run_ids, f"unexpected run ID: {run_id}")
    require(configuration == ("Debug" if run_id.startswith("debug-") else "Release"), f"{run_id} configuration differs")
    require(
        SHA256.fullmatch(run["captureToolingSHA256"]) is not None,
        f"{run_id} capture tooling SHA-256 differs",
    )
    directory = safe_relative_path(run["directory"], f"{run_id} directory")
    require(directory == f"runs/{run_id}", f"{run_id} directory differs")
    paths = {key: _run_path(root, inventory, directory, key, run_id) for key in RUN_FILES}
    preflight = validate_boundary(paths["preflight"], paths["preflightDigest"], "preflight", schema, f"{run_id} preflight")
    postflight = validate_boundary(paths["postflight"], paths["postflightDigest"], "postflight", schema, f"{run_id} postflight")
    evidence = parse_key_values(paths["evidenceManifest"], EVIDENCE_KEYS, f"{run_id} evidence manifest")
    require(evidence["format"] == "1" and evidence["source_commit"] == schema.source_commit, f"{run_id} evidence identity differs")
    require(evidence["configuration"] == configuration and evidence["status"] == "pass", f"{run_id} evidence status differs")
    for key in ("build_manifest_sha256", "raw_log_sha256", "xcresult_sha256", "xcresult_inspection_input_sha256", "xcresult_inspection_result_sha256", "warning_check_sha256"):
        require(SHA256.fullmatch(evidence[key]) is not None, f"{run_id} {key} is invalid")
    require(
        evidence["xcresult_inspection_input_sha256"] == evidence["xcresult_sha256"],
        f"{run_id} inspection input was not bound to raw xcresult",
    )
    raw_data = validate_digest(paths["rawLog"], paths["rawLogDigest"], f"{run_id} raw log")
    require(sha256_bytes(raw_data) == evidence["raw_log_sha256"] and str(len(raw_data)) == evidence["raw_log_bytes"], f"{run_id} raw log differs from evidence manifest")
    warning_data = validate_digest(paths["warningCheck"], paths["warningCheckDigest"], f"{run_id} warning check")
    require(sha256_bytes(warning_data) == evidence["warning_check_sha256"] and str(len(warning_data)) == evidence["warning_check_bytes"], f"{run_id} warning check differs")
    require(b"F2 WARNING CHECK PASS" in warning_data, f"{run_id} warning checker did not pass")
    validate_digest(paths["outerLog"], paths["outerLogDigest"], f"{run_id} outer log")
    validate_outer(paths["outerStatus"], schema, f"{run_id} outer status")
    raw_log_path = evidence["raw_log_path"]
    require(raw_log_path.endswith(".log") and PurePosixPath(raw_log_path).is_absolute(), f"{run_id} raw log path differs")
    prefix = raw_log_path[:-4]
    expected_host = f"{prefix}.products/Build/Products/{configuration}/Plainsong.app/Contents/MacOS/Plainsong"
    monitor = validate_monitor(
        paths["monitorLog"], paths["monitorLogDigest"], paths["monitorSamples"],
        paths["monitorSamplesDigest"], paths["monitorStatus"], paths["monitorStatusDigest"],
        expected_host, run["captureToolingSHA256"], schema, run_id,
    )
    try:
        text = raw_data.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise AuditError(f"{run_id} raw log is not UTF-8") from error
    validate_warning_phase(text)
    validate_warning_negative_control(text)
    timings = validate_timings(text, run_id)
    summary = _json_file(paths["xcresultSummary"], f"{run_id} xcresult summary")
    require(isinstance(summary, dict), f"{run_id} xcresult summary is not an object")
    test_start, test_finish = _summary_times(summary, run_id)
    require(
        preflight <= monitor.started <= monitor.first_sample_finished <= test_start <=
        test_finish <= monitor.last_sample_started <= monitor.finished <= postflight,
        f"{run_id} retained chronology is not enclosed by the monitor and boundaries",
    )
    provenance = load_provenance(
        paths["fullArtifactProvenance"],
        run_id,
        configuration,
        schema,
    )
    if artifact_root is not None:
        validate_artifacts(
            provenance,
            artifact_root,
            run_id,
            configuration,
            schema,
            evidence,
            prefix,
        )
    return {"id": run_id, "timings": timings}


def validate_pack(
    pack_root: Path,
    artifact_root: Path | None,
    expected_inventory_sha256: str | None = None,
    integrity_schema: EvidenceSchema | None = None,
) -> list[dict[str, object]]:
    require(pack_root.is_absolute() and pack_root.is_dir() and not pack_root.is_symlink(), "pack root must be an absolute real directory")
    require(pack_root.resolve(strict=True) == pack_root, "pack root must be canonical")
    if expected_inventory_sha256 is not None:
        require(
            SHA256.fullmatch(expected_inventory_sha256) is not None,
            "expected inventory SHA-256 is invalid",
        )
        require(
            sha256_file(pack_root / "SHA256SUMS") == expected_inventory_sha256,
            "pack inventory trust-root SHA-256 differs",
        )
    current_schema = integrity_schema or load_schema()
    require(
        current_schema.source_archive_sha256 is not None
        and current_schema.source_tree_sha256 is not None,
        "current source-integrity anchors are missing",
    )
    inventory = validate_inventory(pack_root)
    manifest_path = pack_file(pack_root, inventory, "manifest.json", "manifest")
    manifest = _exact_keys(
        _json_file(manifest_path, "manifest.json"),
        {"format", "gate", "schemaSHA256", "sourceCommit", "tooling", "runs", "boundaries"},
        "manifest.json",
    )
    manifest_format = manifest["format"]
    require(
        manifest_format in (2, CURRENT_MANIFEST_FORMAT)
        and manifest["gate"] == "editor-find-f2-retained-evidence",
        "manifest identity differs",
    )
    if manifest_format == 2:
        retained_schema_path = pack_file(
            pack_root,
            inventory,
            "reference/editor-find-f2-evidence/schema.json",
            "retained schema",
        )
        schema = load_schema(retained_schema_path)
    else:
        schema = current_schema
    require(
        schema.source_commit == current_schema.source_commit,
        "retained source differs from the current external source-integrity anchor",
    )
    schema = replace(
        schema,
        source_archive_sha256=current_schema.source_archive_sha256,
        source_tree_sha256=current_schema.source_tree_sha256,
    )
    require(manifest["schemaSHA256"] == schema.digest and manifest["sourceCommit"] == schema.source_commit, "manifest schema/source binding differs")
    auditor_paths = auditor_paths_for_manifest(schema, manifest_format)
    tooling_paths = tuple(
        dict.fromkeys(
            f"reference/{path}"
            for path in schema.capture_tooling_paths + auditor_paths
        )
    )
    tooling = _exact_keys(
        manifest["tooling"],
        {"files", "captureSHA256", "auditorSHA256"},
        "manifest tooling",
    )
    require(isinstance(tooling["files"], list), "manifest tooling files must be an array")
    tooling_records: dict[str, str] = {}
    for record in tooling["files"]:
        record = _exact_keys(record, {"path", "sha256"}, "manifest tooling file")
        path = safe_relative_path(record["path"], "manifest tooling path")
        require(path in tooling_paths and path not in tooling_records, "manifest tooling path differs")
        require(SHA256.fullmatch(record["sha256"]) is not None, "manifest tooling SHA-256 differs")
        require(inventory.get(path) == record["sha256"], f"manifest tooling hash differs for {path}")
        tooling_records[path] = record["sha256"]
    require(tuple(tooling_records) == tooling_paths, "manifest tooling order/set differs")
    require(
        tooling_records["reference/editor-find-f2-evidence/schema.json"] == schema.digest,
        "retained schema differs from the auditor schema",
    )
    retained_reference = pack_root / "reference"
    capture_tooling = tooling_digest(retained_reference, schema.capture_tooling_paths)
    auditor_tooling = tooling_digest(retained_reference, auditor_paths)
    require(
        tooling["captureSHA256"] == capture_tooling
        and tooling["auditorSHA256"] == auditor_tooling,
        "manifest combined tooling hashes differ",
    )
    # The retained references authenticate the exact historical auditor and
    # capture bytes. The isolated live bootstrap authenticates the maintained
    # auditor independently; equality would falsely claim newer code produced
    # these historical runs.
    require(manifest["boundaries"] == {"fullKeystrokeToScreen": "open", "f8HighlightApplyClear": "open", "f9": "open", "combinedTip": "open"}, "manifest overclaims open boundaries")
    require(isinstance(manifest["runs"], list), "manifest runs must be an array")
    require(tuple(run.get("id") for run in manifest["runs"] if isinstance(run, dict)) == schema.run_ids, "manifest run order/set differs")
    require(
        all(run.get("captureToolingSHA256") == capture_tooling for run in manifest["runs"]),
        "run capture tooling binding differs",
    )
    if artifact_root is not None:
        require(artifact_root.is_absolute() and artifact_root.is_dir() and not artifact_root.is_symlink(), "artifact root must be an absolute real directory")
        artifact_root = artifact_root.resolve(strict=True)
        owner_controlled_tree(artifact_root, "full artifact root")
    return [_validate_run(pack_root, inventory, run, schema, artifact_root) for run in manifest["runs"]]
