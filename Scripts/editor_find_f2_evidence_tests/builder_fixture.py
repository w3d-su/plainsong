"""Static authoritative-capture inputs for pack-builder tests."""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path

from editor_find_f2_evidence.artifact_hash import hash_artifact
from editor_find_f2_evidence.builder_inputs import BUILD_KEYS
from editor_find_f2_evidence.schema import load_schema, tooling_digest
from editor_find_f2_evidence.strict_io import sha256_bytes, sha256_file

from .fixture import boundary, digest_record, outer_status, raw_log, write, write_digest


def _key_values(keys: tuple[str, ...], values: dict[str, str]) -> str:
    return "".join(f"{key}={values[key]}\n" for key in keys)


def _monitor_status(run_id: str, configuration: str, prefix: Path) -> str:
    schema = load_schema()
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
    return _key_values(schema.monitor_status_keys, values)


def _build(root: Path, configuration: str) -> tuple[Path, dict[str, str]]:
    schema = load_schema()
    directory = root / "builds" / configuration.lower()
    archive = Path(f"{directory}.source.tar")
    snapshot = Path(f"{directory}.source")
    packages = directory / "SourcePackages"
    write(archive, f"archive:{configuration}\n")
    write(snapshot / "project.yml", f"configuration: {configuration}\n")
    write(packages / "artifacts" / "payload", "artifact\n")
    write(packages / "checkouts" / "source", "checkout\n")
    write(packages / "repositories" / "mutable-cache", "not hash bound\n")
    write(packages / "workspace-state.json", "{}\n")
    xctestrun_relative = "Build/Products/Plainsong_PerformanceTests_macosx.xctestrun"
    manifest = directory / "f2-editor-find-build-manifest.txt"
    values = {
        "format": "5",
        "source_commit": schema.source_commit,
        "configuration": configuration,
        "repository_root": "/private/tmp/f2-source",
        "source_snapshot_path": str(snapshot),
        "source_archive_path": str(archive),
        "source_archive_sha256": sha256_file(archive),
        "source_tree_sha256": hash_artifact(snapshot),
        "build_input_sha256": hash_artifact(snapshot),
        "package_input_path": str(packages),
        "resolved_package_input_sha256": hash_artifact(packages, True),
        "xcodegen_path": "/usr/local/bin/xcodegen",
        "xcodegen_sha256": "0" * 64,
        "destination": "platform=macOS,arch=arm64",
        "budget_mode": "local-hard",
        "host_bundle_sha256": "",
        "xctestrun_relative_path": xctestrun_relative,
        "xctestrun_sha256": "",
    }
    return manifest, values


def _summary() -> bytes:
    base = datetime(2026, 8, 8, tzinfo=timezone.utc).timestamp()
    value = {
        "result": "Passed",
        "passedTests": 2,
        "failedTests": 0,
        "skippedTests": 0,
        "totalTestCount": 2,
        "runtimeWarnings": [
            {"message": "Modifying state during view update, this will cause undefined behavior."}
        ],
        "startTime": base + 1.15,
        "finishTime": base + 1.35,
    }
    return (json.dumps(value, sort_keys=True) + "\n").encode()


def create_builder_inputs(root: Path) -> tuple[dict[str, Path], bytes]:
    schema = load_schema()
    builds = {configuration: _build(root, configuration) for configuration in ("Debug", "Release")}
    prefixes: dict[str, Path] = {}
    for run_id in schema.run_ids:
        configuration = "Debug" if run_id.startswith("debug-") else "Release"
        prefix = root / "captures" / run_id
        prefixes[run_id] = prefix
        manifest, build = builds[configuration]
        host = Path(f"{prefix}.products") / "Build" / "Products" / configuration / "Plainsong.app"
        xctestrun = Path(f"{prefix}.products") / build["xctestrun_relative_path"]
        write(host / "Contents" / "MacOS" / "Plainsong", f"host:{configuration}\n")
        write(xctestrun, f"xctestrun:{configuration}\n")
        build["host_bundle_sha256"] = hash_artifact(host)
        build["xctestrun_sha256"] = hash_artifact(xctestrun)
        write(manifest, _key_values(BUILD_KEYS, build))

        write(Path(f"{prefix}.preflight.txt"), boundary("preflight", "2026-08-08T00:00:00Z", schema))
        write_digest(Path(f"{prefix}.preflight.txt"))
        write(Path(f"{prefix}.postflight.txt"), boundary("postflight", "2026-08-08T00:00:02Z", schema))
        write_digest(Path(f"{prefix}.postflight.txt"))
        write(Path(f"{prefix}.competition-monitor.log"), b"")
        write_digest(Path(f"{prefix}.competition-monitor.log"))
        samples = (
            "sequence=1 started_utc=2026-08-08T00:00:01.000000Z finished_utc=2026-08-08T00:00:01.100000Z match_count=0\n"
            "sequence=2 started_utc=2026-08-08T00:00:01.200000Z finished_utc=2026-08-08T00:00:01.300000Z match_count=0\n"
            "sequence=3 started_utc=2026-08-08T00:00:01.400000Z finished_utc=2026-08-08T00:00:01.500000Z match_count=0\n"
        )
        write(Path(f"{prefix}.competition-monitor.samples.txt"), samples)
        write_digest(Path(f"{prefix}.competition-monitor.samples.txt"))
        write(Path(f"{prefix}.competition-monitor.status.txt"), _monitor_status(run_id, configuration, prefix))
        write_digest(Path(f"{prefix}.competition-monitor.status.txt"))
        raw = raw_log().encode()
        warning = b"F2 WARNING CHECK PASS pre=3 measured=0 post=0\n"
        write(Path(f"{prefix}.log"), raw)
        write(Path(f"{prefix}.log.sha256"), digest_record(Path(f"{prefix}.log")))
        write(Path(f"{prefix}.warning-check.txt"), warning)
        write_digest(Path(f"{prefix}.warning-check.txt"))
        write(Path(f"{prefix}.outer.log"), b"")
        write_digest(Path(f"{prefix}.outer.log"))
        write(Path(f"{prefix}.outer.status.txt"), outer_status(schema))
        write(Path(f"{prefix}.xcresult/payload"), f"xcresult:{run_id}\n")
        write(Path(f"{prefix}.inspection.xcresult/payload"), f"xcresult:{run_id}\n")
        evidence_keys = (
            "format", "source_commit", "configuration", "build_manifest_path",
            "build_manifest_sha256", "raw_log_path", "raw_log_sha256", "raw_log_bytes",
            "xcresult_path", "xcresult_sha256", "xcresult_inspection_path",
            "xcresult_inspection_input_sha256", "xcresult_inspection_result_sha256",
            "warning_check_path", "warning_check_sha256", "warning_check_bytes", "status",
        )
        xcresult_sha = hash_artifact(Path(f"{prefix}.xcresult"))
        evidence = {
            "format": "1",
            "source_commit": schema.source_commit,
            "configuration": configuration,
            "build_manifest_path": str(manifest),
            "build_manifest_sha256": sha256_file(manifest),
            "raw_log_path": f"{prefix}.log",
            "raw_log_sha256": sha256_bytes(raw),
            "raw_log_bytes": str(len(raw)),
            "xcresult_path": f"{prefix}.xcresult",
            "xcresult_sha256": xcresult_sha,
            "xcresult_inspection_path": f"{prefix}.inspection.xcresult",
            "xcresult_inspection_input_sha256": xcresult_sha,
            "xcresult_inspection_result_sha256": hash_artifact(Path(f"{prefix}.inspection.xcresult")),
            "warning_check_path": f"{prefix}.warning-check.txt",
            "warning_check_sha256": sha256_bytes(warning),
            "warning_check_bytes": str(len(warning)),
            "status": "pass",
        }
        write(Path(f"{prefix}.evidence-manifest.txt"), _key_values(evidence_keys, evidence))
    return prefixes, _summary()
