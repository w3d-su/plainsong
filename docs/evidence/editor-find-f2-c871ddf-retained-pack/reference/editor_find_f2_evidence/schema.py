"""Strict loading of the capture/auditor schema shared with shell."""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

from .errors import AuditError, require


@dataclass(frozen=True)
class EvidenceSchema:
    path: Path
    digest: str
    source_commit: str
    process_filter: str
    process_ownership_rule: str
    capture_tooling_paths: tuple[str, ...]
    auditor_tooling_paths: tuple[str, ...]
    monitor_format: int
    monitor_interval_ms: int
    monitor_max_gap_ms: int
    monitor_status_keys: tuple[str, ...]
    outer_format: int
    run_timeout_seconds: int
    outer_status_keys: tuple[str, ...]
    runner_environment_policy: str
    run_ids: tuple[str, ...]


def _unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise AuditError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_json_bytes(data: bytes, label: str) -> object:
    try:
        return json.loads(
            data.decode("utf-8", errors="strict"),
            object_pairs_hook=_unique_object,
            parse_constant=lambda value: (_ for _ in ()).throw(
                AuditError(f"non-finite JSON number in {label}: {value}")
            ),
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise AuditError(f"{label} is not strict UTF-8 JSON: {error}") from error


def _exact_keys(value: object, keys: set[str], label: str) -> dict[str, object]:
    require(isinstance(value, dict), f"{label} must be an object")
    require(set(value) == keys, f"{label} keys differ: {sorted(value)}")
    return value


def _tooling_paths(value: object, label: str) -> tuple[str, ...]:
    require(isinstance(value, list) and value, f"{label} must be a non-empty array")
    require(all(isinstance(item, str) for item in value), f"{label} contains a non-string")
    paths = tuple(value)
    for item in paths:
        path = PurePosixPath(item)
        require(
            not path.is_absolute()
            and path.as_posix() == item
            and all(part not in ("", ".", "..") for part in path.parts),
            f"{label} contains an unsafe path: {item}",
        )
    require(len(set(paths)) == len(paths), f"{label} contains duplicate paths")
    return paths


def load_schema() -> EvidenceSchema:
    path = Path(__file__).resolve().parent.parent / "editor-find-f2-evidence" / "schema.json"
    data = path.read_bytes()
    root = _exact_keys(
        load_json_bytes(data, "schema.json"),
        {
            "schemaVersion",
            "sourceCommit",
            "processFilter",
            "processOwnershipRule",
            "captureToolingPaths",
            "auditorToolingPaths",
            "monitor",
            "outer",
            "runnerEnvironmentPolicy",
            "expectedRunIDs",
        },
        "schema.json",
    )
    require(root["schemaVersion"] == 1, "unsupported schema version")
    monitor = _exact_keys(
        root["monitor"],
        {"format", "sampleIntervalMilliseconds", "maximumSampleGapMilliseconds", "statusKeys"},
        "monitor schema",
    )
    outer = _exact_keys(
        root["outer"],
        {"format", "runTimeoutSeconds", "statusKeys"},
        "outer schema",
    )
    run_ids = root["expectedRunIDs"]
    require(isinstance(run_ids, list) and all(isinstance(item, str) for item in run_ids), "invalid run IDs")
    require(len(set(run_ids)) == len(run_ids) == 6, "schema must name six unique runs")
    return EvidenceSchema(
        path=path,
        digest=hashlib.sha256(data).hexdigest(),
        source_commit=str(root["sourceCommit"]),
        process_filter=str(root["processFilter"]),
        process_ownership_rule=str(root["processOwnershipRule"]),
        capture_tooling_paths=_tooling_paths(root["captureToolingPaths"], "capture tooling paths"),
        auditor_tooling_paths=_tooling_paths(root["auditorToolingPaths"], "auditor tooling paths"),
        monitor_format=int(monitor["format"]),
        monitor_interval_ms=int(monitor["sampleIntervalMilliseconds"]),
        monitor_max_gap_ms=int(monitor["maximumSampleGapMilliseconds"]),
        monitor_status_keys=tuple(monitor["statusKeys"]),
        outer_format=int(outer["format"]),
        run_timeout_seconds=int(outer["runTimeoutSeconds"]),
        outer_status_keys=tuple(outer["statusKeys"]),
        runner_environment_policy=str(root["runnerEnvironmentPolicy"]),
        run_ids=tuple(run_ids),
    )


def tooling_digest(root: Path, paths: tuple[str, ...]) -> str:
    digest = hashlib.sha256()
    for relative in paths:
        encoded = relative.encode("utf-8")
        data = (root / relative).read_bytes()
        digest.update(len(encoded).to_bytes(8, "big"))
        digest.update(encoded)
        digest.update(len(data).to_bytes(8, "big"))
        digest.update(data)
    return digest.hexdigest()
