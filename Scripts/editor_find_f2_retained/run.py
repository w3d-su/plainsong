from __future__ import annotations

from .boundary import validate_run_boundary_capture
from .competition import validate_competition_monitor
from .context import (
    AUTHORITATIVE_RUN_TIMEOUT_SECONDS,
    EVIDENCE_KEYS,
    EXPECTED_RUN_IDENTITIES,
    FINAL_TOKEN_KEYS,
    RUNNER_ENVIRONMENT_POLICY,
    SOURCE_COMMIT,
    SOURCE_TOKEN_KEYS,
    WARNING_TOKEN_KEYS,
)
from .core import (
    AuditError,
    load_json,
    loads_json,
    pack_file,
    parse_digest,
    parse_key_values,
    require,
    require_sha256,
    sha256_bytes,
    sha256_file,
)
from .logs import (
    extract_timings,
    parse_summary_timestamp,
    parse_tokens,
    validate_summary,
    validate_warning_negative_control,
    validate_warning_phase,
)
from .provenance import validate_full_provenance, validate_run_paths

def validate_run(
    root: Path,
    inventory: dict[str, str],
    run: dict,
    build: dict[str, str],
    build_manifest_sha256: str,
    environment: dict,
) -> dict:
    run_id = run["id"]
    expected_identity = EXPECTED_RUN_IDENTITIES[run_id]
    configuration = run["configuration"]
    files = run["files"]
    paths = {
        key: pack_file(root, inventory, relative, f"{run_id} {key}")
        for key, relative in files.items()
    }
    preflight_time = validate_run_boundary_capture(
        paths["preflight"],
        paths["preflightDigest"],
        "preflight",
        run_id,
    )
    monitor = validate_competition_monitor(
        paths["competitionMonitor"],
        paths["competitionMonitorDigest"],
        paths["competitionMonitorSamples"],
        paths["competitionMonitorSamplesDigest"],
        paths["runOwnedProcesses"],
        paths["runOwnedProcessesDigest"],
        paths["competitionMonitorStatus"],
        paths["competitionMonitorStatusDigest"],
        run_id,
        configuration,
    )
    raw_data = paths["rawLog"].read_bytes()
    raw_sha, raw_bytes = parse_digest(paths["rawLogDigest"], f"{run_id} raw-log digest")
    require(raw_sha == sha256_bytes(raw_data) and raw_bytes == len(raw_data), f"{run_id}: raw-log digest differs")
    require(
        raw_sha == expected_identity["rawLogSHA256"],
        f"{run_id}: raw log is not the frozen final-six artifact",
    )
    try:
        raw_text = raw_data.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise AuditError(f"{run_id}: raw log is not UTF-8: {error}") from error
    timings = extract_timings(raw_text, run_id)
    phase = validate_warning_phase(raw_text)
    require(
        phase["id"] == expected_identity["phaseId"],
        f"{run_id}: warning phase ID is not the frozen final-six identity",
    )
    validate_warning_negative_control(raw_text)

    evidence = parse_key_values(paths["evidenceManifest"], EVIDENCE_KEYS, f"{run_id} evidence manifest")
    require(evidence["format"] == "1" and evidence["status"] == "pass", f"{run_id}: evidence status differs")
    require(evidence["source_commit"] == SOURCE_COMMIT, f"{run_id}: evidence source differs")
    require(evidence["configuration"] == configuration, f"{run_id}: evidence configuration differs")
    expected_build_manifest_path = (
        build["source_snapshot_path"][: -len(".source")]
        + "/f2-editor-find-build-manifest.txt"
    )
    require(
        evidence["build_manifest_path"] == expected_build_manifest_path,
        f"{run_id}: evidence build-manifest original path differs",
    )
    require(evidence["build_manifest_sha256"] == build_manifest_sha256, f"{run_id}: build manifest digest differs")
    require(evidence["raw_log_sha256"] == raw_sha, f"{run_id}: evidence raw-log digest differs")
    require(evidence["raw_log_bytes"] == str(raw_bytes), f"{run_id}: evidence raw-log bytes differ")
    for key in (
        "xcresult_sha256",
        "xcresult_inspection_input_sha256",
        "xcresult_inspection_result_sha256",
        "warning_check_sha256",
    ):
        require_sha256(evidence[key], f"{run_id} evidence {key}")
    require(
        evidence["xcresult_inspection_input_sha256"] == evidence["xcresult_sha256"],
        f"{run_id}: inspection input was not the raw xcresult",
    )
    require(
        evidence["xcresult_sha256"] == expected_identity["xcresultSHA256"]
        and evidence["xcresult_inspection_result_sha256"]
        == expected_identity["inspectionXcresultSHA256"],
        f"{run_id}: xcresult identity is not the frozen final-six artifact",
    )

    warning_data = paths["warningCheck"].read_bytes()
    warning_sha, warning_bytes = parse_digest(paths["warningCheckDigest"], f"{run_id} warning digest")
    require(
        warning_sha == sha256_bytes(warning_data) and warning_bytes == len(warning_data),
        f"{run_id}: warning-check digest differs",
    )
    require(evidence["warning_check_sha256"] == warning_sha, f"{run_id}: evidence warning digest differs")
    require(
        warning_sha == expected_identity["warningCheckSHA256"],
        f"{run_id}: warning check is not the frozen final-six artifact",
    )
    require(evidence["warning_check_bytes"] == str(warning_bytes), f"{run_id}: evidence warning bytes differ")
    try:
        warning_text = warning_data.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise AuditError(f"{run_id}: warning check is not UTF-8: {error}") from error
    require(warning_text.endswith("\n"), f"{run_id}: warning check must end with LF")
    warning_lines = warning_text.splitlines()
    require(len(warning_lines) == 2, f"{run_id}: warning check must have two lines")
    source = parse_tokens(warning_lines[0], "F2 SOURCE CHECK PASS", SOURCE_TOKEN_KEYS, f"{run_id} source check")
    warning = parse_tokens(warning_lines[1], "F2 WARNING CHECK PASS", WARNING_TOKEN_KEYS, f"{run_id} warning check")
    expected_source = {
        "commit": SOURCE_COMMIT,
        "configuration": configuration,
        "budget-mode": "local-hard",
        "build-manifest-readonly": "true",
        "build-manifest-sha256": build_manifest_sha256,
        "exact-source-readonly": "true",
        "build-input-sha256": build["build_input_sha256"],
        "resolved-package-input-readonly": "true",
        "resolved-package-input-sha256": build["resolved_package_input_sha256"],
        "snapshot-readonly": "true",
        "host-bundle-sha256": build["host_bundle_sha256"],
        "xctestrun-sha256": build["xctestrun_sha256"],
        "raw-log-readonly": "true",
        "raw-log-sha256": raw_sha,
        "xcresult-readonly": "true",
        "xcresult-sha256": evidence["xcresult_sha256"],
        "xcresult-inspection-input-sha256": evidence["xcresult_inspection_input_sha256"],
    }
    for key, expected in expected_source.items():
        require(source[key] == expected, f"{run_id}: source-check {key} differs")
    expected_warning = {
        "id": phase["id"],
        "edits": "5",
        "raw-known-pre": "3",
        "raw-known-measured": "0",
        "raw-known-post": "0",
        "unknown-swiftui": "0",
        "raw-log-sha256": raw_sha,
        "budget-mode": "local-hard",
        "budget-mode-markers": "2",
        "xcresult-input-sha256": evidence["xcresult_sha256"],
        "xcresult-coalesced-known": "1",
    }
    for key, expected in expected_warning.items():
        require(warning[key] == expected, f"{run_id}: warning-check {key} differs")
    original_run_prefix = validate_run_paths(evidence, source)
    require(
        monitor["allowedRunPrefix"] == original_run_prefix,
        f"{run_id}: competition-monitor allowed prefix differs from the measured run",
    )

    evidence_sha = sha256_file(paths["evidenceManifest"])
    outer_data = paths["outerLog"].read_bytes()
    outer_sha, outer_bytes = parse_digest(paths["outerLogDigest"], f"{run_id} outer digest")
    require(outer_sha == sha256_bytes(outer_data) and outer_bytes == len(outer_data), f"{run_id}: outer digest differs")
    status_record = parse_key_values(
        paths["outerStatus"],
        (
            "format",
            "wrapper_exit_status",
            "capture_exit_status",
            "run_timeout_seconds",
            "timed_out",
            "termination_failed",
            "runner_environment_policy",
        ),
        f"{run_id} outer status",
    )
    require(
        status_record
        == {
            "format": "3",
            "wrapper_exit_status": "0",
            "capture_exit_status": "0",
            "run_timeout_seconds": str(AUTHORITATIVE_RUN_TIMEOUT_SECONDS),
            "timed_out": "0",
            "termination_failed": "0",
            "runner_environment_policy": RUNNER_ENVIRONMENT_POLICY,
        },
        f"{run_id}: outer capture status/timeout/environment policy differs",
    )
    require(outer_data.startswith(raw_data + warning_data), f"{run_id}: outer transcript is not raw+warning")
    final_data = outer_data[len(raw_data) + len(warning_data) :]
    try:
        final_text = final_data.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise AuditError(f"{run_id}: final transcript is not UTF-8: {error}") from error
    require(final_text.endswith("\n") and len(final_text.splitlines()) == 1, f"{run_id}: final transcript line differs")
    final = parse_tokens(final_text.rstrip("\n"), "F2 FINAL INTEGRITY PASS", FINAL_TOKEN_KEYS, f"{run_id} final check")
    expected_final = {
        "commit": SOURCE_COMMIT,
        "configuration": configuration,
        "build-manifest-readonly": "true",
        "build-manifest-sha256": build_manifest_sha256,
        "exact-source-readonly": "true",
        "resolved-package-input-readonly": "true",
        "resolved-package-input-sha256": build["resolved_package_input_sha256"],
        "snapshot-readonly": "true",
        "raw-log-readonly": "true",
        "raw-log-sha256": raw_sha,
        "xcresult-readonly": "true",
        "xcresult-sha256": evidence["xcresult_sha256"],
        "xcresult-inspection-readonly": "true",
        "xcresult-inspection-input-sha256": evidence["xcresult_inspection_input_sha256"],
        "xcresult-inspection-result-sha256": evidence["xcresult_inspection_result_sha256"],
        "warning-check-readonly": "true",
        "warning-check-sha256": warning_sha,
        "evidence-manifest-readonly": "true",
        "evidence-manifest-sha256": evidence_sha,
    }
    for key, expected in expected_final.items():
        require(final[key] == expected, f"{run_id}: final-check {key} differs")

    summary_data = paths["xcresultSummary"].read_bytes()
    summary = loads_json(summary_data, f"{run_id} xcresult summary")
    validate_summary(summary, environment, f"{run_id} xcresult summary")
    summary_provenance = parse_key_values(
        paths["summaryProvenance"],
        (
            "format",
            "source_commit",
            "configuration",
            "run_id",
            "command",
            "xcresult_sha256",
            "inspection_copy_input_sha256",
            "inspection_copy_disposition",
            "summary_sha256",
            "summary_bytes",
            "xcresulttool_exit_status",
        ),
        f"{run_id} summary provenance",
    )
    expected_summary_values = {
        "format": "1",
        "source_commit": SOURCE_COMMIT,
        "configuration": configuration,
        "run_id": run_id,
        "command": (
            "/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcresulttool "
            "get test-results summary --compact --path FRESH_COPY"
        ),
        "xcresult_sha256": evidence["xcresult_sha256"],
        "inspection_copy_input_sha256": evidence["xcresult_sha256"],
        "inspection_copy_disposition": "deleted-after-summary-read",
        "summary_sha256": sha256_bytes(summary_data),
        "summary_bytes": str(len(summary_data)),
        "xcresulttool_exit_status": "0",
    }
    for key, expected in expected_summary_values.items():
        require(summary_provenance[key] == expected, f"{run_id}: summary provenance {key} differs")
    provenance = validate_full_provenance(
        load_json(paths["fullArtifactProvenance"], f"{run_id} full-artifact provenance"),
        run_id,
        configuration,
        build,
        build_manifest_sha256,
        evidence,
        source,
    )
    postflight_time = validate_run_boundary_capture(
        paths["postflight"],
        paths["postflightDigest"],
        "postflight",
        run_id,
    )
    require(postflight_time >= preflight_time, f"{run_id}: postflight precedes preflight")
    test_start = parse_summary_timestamp(summary.get("startTime"), f"{run_id} summary startTime")
    test_finish = parse_summary_timestamp(summary.get("finishTime"), f"{run_id} summary finishTime")
    require(test_finish > test_start, f"{run_id}: xcresult interval is not positive")
    require(
        preflight_time <= test_start <= test_finish <= postflight_time,
        f"{run_id}: test interval is not enclosed by preflight/postflight captures",
    )
    require(
        preflight_time <= monitor["started"]
        <= monitor["firstSampleFinished"] <= test_start
        <= test_finish <= monitor["runnerFinishedSampleStarted"]
        <= monitor["finished"] <= postflight_time,
        f"{run_id}: competition-monitor lifecycle does not enclose the xcresult interval",
    )
    return {
        "id": run_id,
        "configuration": configuration,
        "timings": timings,
        "summary": summary,
        "provenance": provenance,
        "build": build,
        "phaseId": phase["id"],
        "rawLogSHA256": raw_sha,
        "xcresultSHA256": evidence["xcresult_sha256"],
        "summaryStart": test_start,
        "summaryFinish": test_finish,
    }
