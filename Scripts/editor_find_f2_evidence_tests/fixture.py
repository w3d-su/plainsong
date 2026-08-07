"""Build small sealed evidence packs without launching Xcode."""

from __future__ import annotations

import json
import os
import shutil
from datetime import datetime, timezone
from pathlib import Path
from typing import Union

from editor_find_f2_evidence.artifact_hash import hash_artifact
from editor_find_f2_evidence.pack import EXPECTED_ARTIFACTS
from editor_find_f2_evidence.schema import load_schema, tooling_digest
from editor_find_f2_evidence.strict_io import sha256_bytes, sha256_file


def write(path: Path, data: Union[bytes, str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data.encode() if isinstance(data, str) else data)


def digest_record(path: Path) -> str:
    data = path.read_bytes()
    return f"sha256={sha256_bytes(data)}\nbytes={len(data)}\n"


def write_digest(path: Path) -> None:
    write(Path(str(path) + ".sha256"), digest_record(path))


def boundary(phase: str, timestamp: str, schema: object) -> str:
    return (
        "format=1\n"
        f"phase={phase}\n"
        f"captured_utc={timestamp}\n"
        f"source_commit={schema.source_commit}\n"
        "source_status=clean\n"
        f"process_filter={schema.process_filter}\n"
        "competing_process_lines=0\n"
        "load_average_1m=1.00\n"
        "thermal_warning=none\n"
        "power_source=AC\n"
    )


def raw_log() -> str:
    warning = "warning: [SwiftUI] Modifying state during view update, this will cause undefined behavior.\n"
    return (
        warning * 3
        + "F2 PERF budget mode local-hard\n"
        + "F2_WARNING_PHASE_BEGIN id=12345678-1234-1234-1234-123456789abc edits=5\n"
        + "F2 PERF production WorkspaceWindow find-open edit 1MB admission median 1.000 ms samples [0.800, 0.900, 1.000, 1.100, 1.200]; state-update receipt median 5.000 ms max 7.000 ms samples [3.000, 4.000, 5.000, 6.000, 7.000]\n"
        + "F2_WARNING_PHASE_END id=12345678-1234-1234-1234-123456789abc edits=5\n"
        + "F2 PERF find query zero 1MB median 100.000 ms samples [90.000, 100.000, 110.000] (0 retained, truncated=false)\n"
        + "F2 PERF find query sparse 1MB median 120.000 ms samples [110.000, 120.000, 130.000] (1 retained, truncated=false)\n"
        + "F2 PERF find query dense-truncated 1MB median 600.000 ms samples [550.000, 600.000, 650.000] (10000 retained, truncated=true)\n"
        + "F2 PERF budget mode local-hard\n"
        + "** TEST EXECUTE SUCCEEDED **\n"
    )


def monitor_status(run_id: str, configuration: str, schema: object) -> str:
    prefix = f"/private/tmp/f2/{run_id}"
    host = f"{prefix}.products/Build/Products/{configuration}/Plainsong.app/Contents/MacOS/Plainsong"
    values = {
        "format": str(schema.monitor_format),
        "monitor_pid": "100",
        "runner_pid": "200",
        "started_utc": "2026-08-08T00:00:01.000000Z",
        "finished_utc": "2026-08-08T00:00:01.500000Z",
        "first_sample_finished_utc": "2026-08-08T00:00:01.100000Z",
        "last_sample_started_utc": "2026-08-08T00:00:01.400000Z",
        "sample_interval_ms": str(schema.monitor_interval_ms),
        "sample_count": "3",
        "match_count": "0",
        "process_filter": schema.process_filter,
        "process_ownership_rule": schema.process_ownership_rule,
        "capture_tooling_sha256": tooling_digest(
            Path(__file__).resolve().parent.parent,
            schema.capture_tooling_paths,
        ),
        "allowed_host_executable": host,
        "exit_status": "0",
    }
    return "".join(f"{key}={values[key]}\n" for key in schema.monitor_status_keys)


def outer_status(schema: object) -> str:
    values = {
        "format": str(schema.outer_format),
        "wrapper_exit_status": "0",
        "capture_exit_status": "0",
        "monitor_exit_status": "0",
        "postflight_exit_status": "0",
        "run_timeout_seconds": str(schema.run_timeout_seconds),
        "timed_out": "0",
        "termination_failed": "0",
        "runner_environment_policy": schema.runner_environment_policy,
    }
    return "".join(f"{key}={values[key]}\n" for key in schema.outer_status_keys)


def evidence_manifest(run_id: str, configuration: str, raw: bytes, warning: bytes, schema: object) -> str:
    prefix = f"/private/tmp/f2/{run_id}"
    zeros = "0" * 64
    values = {
        "format": "1",
        "source_commit": schema.source_commit,
        "configuration": configuration,
        "build_manifest_path": f"{prefix}.build-manifest.txt",
        "build_manifest_sha256": zeros,
        "raw_log_path": f"{prefix}.log",
        "raw_log_sha256": sha256_bytes(raw),
        "raw_log_bytes": str(len(raw)),
        "xcresult_path": f"{prefix}.xcresult",
        "xcresult_sha256": zeros,
        "xcresult_inspection_path": f"{prefix}.inspection.xcresult",
        "xcresult_inspection_input_sha256": zeros,
        "xcresult_inspection_result_sha256": zeros,
        "warning_check_path": f"{prefix}.warning-check.txt",
        "warning_check_sha256": sha256_bytes(warning),
        "warning_check_bytes": str(len(warning)),
        "status": "pass",
    }
    keys = (
        "format", "source_commit", "configuration", "build_manifest_path",
        "build_manifest_sha256", "raw_log_path", "raw_log_sha256", "raw_log_bytes",
        "xcresult_path", "xcresult_sha256", "xcresult_inspection_path",
        "xcresult_inspection_input_sha256", "xcresult_inspection_result_sha256",
        "warning_check_path", "warning_check_sha256", "warning_check_bytes", "status",
    )
    return "".join(f"{key}={values[key]}\n" for key in keys)


def create_artifacts(root: Path, run_id: str) -> dict[str, dict[str, str]]:
    records: dict[str, dict[str, str]] = {}
    for name, (kind, hash_mode) in EXPECTED_ARTIFACTS.items():
        relative = f"{run_id}/{name}"
        path = root / relative
        if kind == "file":
            write(path, f"{run_id}:{name}\n")
        elif hash_mode == "resolved-package-input-sha256":
            write(path / "artifacts" / "payload", b"artifact")
            write(path / "checkouts" / "source", b"checkout")
            write(path / "workspace-state.json", "{}\n")
        else:
            write(path / "payload", f"{run_id}:{name}\n")
        digest = (
            sha256_file(path)
            if hash_mode == "file-sha256"
            else hash_artifact(path, hash_mode == "resolved-package-input-sha256")
        )
        records[name] = {
            "originalPath": f"/private/tmp/f2/{run_id}/{name}",
            "artifactRootPath": relative,
            "hashMode": hash_mode,
            "sha256": digest,
        }
    return records


def rewrite_inventory(root: Path) -> None:
    paths = sorted(
        path.relative_to(root).as_posix()
        for path in root.rglob("*")
        if path.is_file() and path.name != "SHA256SUMS"
    )
    write(root / "SHA256SUMS", "".join(f"{sha256_file(root / path)}  {path}\n" for path in paths))


def create_pack(pack_root: Path, artifact_root: Path) -> None:
    schema = load_schema()
    scripts = Path(__file__).resolve().parent.parent
    tooling: list[dict[str, str]] = []
    source_paths = tuple(dict.fromkeys(schema.capture_tooling_paths + schema.auditor_tooling_paths))
    for source_relative in source_paths:
        relative = f"reference/{source_relative}"
        source = scripts / source_relative
        destination = pack_root / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
        tooling.append({"path": relative, "sha256": sha256_file(destination)})
    runs: list[dict[str, str]] = []
    for run_id in schema.run_ids:
        configuration = "Debug" if run_id.startswith("debug-") else "Release"
        directory = pack_root / "runs" / run_id
        write(directory / "preflight.txt", boundary("preflight", "2026-08-08T00:00:00Z", schema))
        write_digest(directory / "preflight.txt")
        write(directory / "postflight.txt", boundary("postflight", "2026-08-08T00:00:02Z", schema))
        write_digest(directory / "postflight.txt")
        write(directory / "competition-monitor.log", b"")
        write_digest(directory / "competition-monitor.log")
        samples = (
            "sequence=1 started_utc=2026-08-08T00:00:01.000000Z finished_utc=2026-08-08T00:00:01.100000Z match_count=0\n"
            "sequence=2 started_utc=2026-08-08T00:00:01.200000Z finished_utc=2026-08-08T00:00:01.300000Z match_count=0\n"
            "sequence=3 started_utc=2026-08-08T00:00:01.400000Z finished_utc=2026-08-08T00:00:01.500000Z match_count=0\n"
        )
        write(directory / "competition-monitor.samples.txt", samples)
        write_digest(directory / "competition-monitor.samples.txt")
        write(directory / "competition-monitor.status.txt", monitor_status(run_id, configuration, schema))
        write_digest(directory / "competition-monitor.status.txt")
        raw = raw_log().encode()
        warning = b"F2 WARNING CHECK PASS pre=3 measured=0 post=0\n"
        write(directory / "raw.log", raw)
        write_digest(directory / "raw.log")
        write(directory / "warning-check.txt", warning)
        write_digest(directory / "warning-check.txt")
        write(directory / "evidence-manifest.txt", evidence_manifest(run_id, configuration, raw, warning, schema))
        write(directory / "outer.log", b"")
        write_digest(directory / "outer.log")
        write(directory / "outer.status.txt", outer_status(schema))
        base_time = datetime(2026, 8, 8, tzinfo=timezone.utc).timestamp()
        summary = {
            "result": "Passed", "passedTests": 2, "failedTests": 0,
            "skippedTests": 0, "totalTestCount": 2,
            "runtimeWarnings": [{"message": "Modifying state during view update, this will cause undefined behavior."}],
            "startTime": base_time + 1.15, "finishTime": base_time + 1.35,
        }
        write(directory / "xcresult-summary.json", json.dumps(summary, sort_keys=True) + "\n")
        provenance = {
            "format": 1,
            "sourceCommit": schema.source_commit,
            "configuration": configuration,
            "runId": run_id,
            "retainedInPack": False,
            "retainedAtArtifactRoot": True,
            "verificationScope": "owner-local-full-artifact",
            "artifacts": create_artifacts(artifact_root, run_id),
        }
        write(directory / "full-artifact-provenance.json", json.dumps(provenance, sort_keys=True) + "\n")
        runs.append(
            {
                "id": run_id,
                "configuration": configuration,
                "directory": f"runs/{run_id}",
                "captureToolingSHA256": tooling_digest(
                    scripts,
                    schema.capture_tooling_paths,
                ),
            }
        )
    manifest = {
        "format": 2,
        "gate": "editor-find-f2-retained-evidence",
        "schemaSHA256": schema.digest,
        "sourceCommit": schema.source_commit,
        "tooling": {
            "files": tooling,
            "captureSHA256": tooling_digest(scripts, schema.capture_tooling_paths),
            "auditorSHA256": tooling_digest(scripts, schema.auditor_tooling_paths),
        },
        "runs": runs,
        "boundaries": {
            "fullKeystrokeToScreen": "open",
            "f8HighlightApplyClear": "open",
            "f9": "open",
            "combinedTip": "open",
        },
    }
    write(pack_root / "manifest.json", json.dumps(manifest, sort_keys=True) + "\n")
    rewrite_inventory(pack_root)
    os.chmod(pack_root, 0o700)
