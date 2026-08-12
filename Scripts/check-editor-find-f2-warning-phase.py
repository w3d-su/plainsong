#!/usr/bin/python3 -I

"""Validate the narrow F2 hosted SwiftUI-warning exception."""

from __future__ import annotations

import sys

if not sys.flags.isolated:
    raise SystemExit(
        "F2 tooling entry point requires isolated Python; use /usr/bin/python3 -I"
    )

import hashlib
import json
import re
import subprocess
from pathlib import Path


EXPECTED_EDIT_COUNT = 5
EXPECTED_PREMEASURE_WARNING_COUNT = 3
WARNING_MESSAGE = (
    "Modifying state during view update, this will cause undefined behavior."
)
MARKER_PATTERN = re.compile(
    r"F2_WARNING_PHASE_(BEGIN|END) "
    r"id=([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}) "
    r"edits=([0-9]+)\s*$"
)
SWIFTUI_MESSAGE_PATTERN = re.compile(r"\[SwiftUI\] (.+?)\s*$")
BUDGET_MODE_PATTERN = re.compile(
    r"F2 PERF budget mode (local-hard|ci-informational)\s*$"
)
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")


def fail(message: str) -> None:
    print(f"F2 WARNING CHECK FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_xcresult_summary(result_path: Path) -> dict:
    command = [
        "/usr/bin/xcrun",
        "xcresulttool",
        "get",
        "test-results",
        "summary",
        "--path",
        str(result_path),
    ]
    completed = subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        fail(
            "xcresulttool could not read "
            f"{result_path}: {completed.stderr.strip()}"
        )
    try:
        return json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        fail(f"xcresulttool returned invalid JSON: {error}")


def validate_artifact_digest(result_path: Path, expected_sha256: str) -> None:
    if SHA256_PATTERN.fullmatch(expected_sha256) is None:
        fail(f"invalid expected xcresult SHA-256: {expected_sha256!r}")

    hasher = Path(__file__).with_name("hash-editor-find-f2-artifact.py")
    completed = subprocess.run(
        ["/usr/bin/python3", "-I", str(hasher), str(result_path)],
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        fail(
            "could not hash xcresult inspection input: "
            f"{completed.stderr.strip()}"
        )
    actual_sha256 = completed.stdout.strip()
    if actual_sha256 != expected_sha256:
        fail(
            "xcresult inspection input differs from the sealed raw result: "
            f"{actual_sha256} != {expected_sha256}"
        )


def validate_xcresult(summary: dict) -> int:
    if summary.get("result") != "Passed":
        fail(f"xcresult result is {summary.get('result')!r}, not 'Passed'")
    if summary.get("failedTests") != 0 or summary.get("passedTests") != 2:
        fail(
            "expected two passing F2 tests and zero failures; got "
            f"passed={summary.get('passedTests')!r}, "
            f"failed={summary.get('failedTests')!r}"
        )

    runtime_warnings = summary.get("runtimeWarnings")
    if not isinstance(runtime_warnings, list):
        fail("xcresult runtimeWarnings is missing or not an array")
    messages = [warning.get("message") for warning in runtime_warnings]
    if messages != [WARNING_MESSAGE]:
        fail(
            "xcresult must contain exactly one coalesced known Runtime Warning "
            f"issue; got {messages!r}"
        )
    return len(runtime_warnings)


def validate_log_digest(log_path: Path, expected_sha256: str) -> None:
    if SHA256_PATTERN.fullmatch(expected_sha256) is None:
        fail(f"invalid expected raw-log SHA-256: {expected_sha256!r}")

    digest = hashlib.sha256()
    try:
        with log_path.open("rb") as handle:
            while True:
                chunk = handle.read(1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
    except OSError as error:
        fail(f"could not hash {log_path}: {error}")

    actual_sha256 = digest.hexdigest()
    if actual_sha256 != expected_sha256:
        fail(
            "raw log differs from its streaming capture digest: "
            f"{actual_sha256} != {expected_sha256}"
        )


def validate_log(log_path: Path) -> tuple[str, int, int, int]:
    try:
        lines = log_path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError as error:
        fail(f"could not read {log_path}: {error}")

    markers: list[tuple[int, str, str, int]] = []
    for line_number, line in enumerate(lines, start=1):
        for match in MARKER_PATTERN.finditer(line):
            markers.append(
                (
                    line_number,
                    match.group(1),
                    match.group(2),
                    int(match.group(3)),
                )
            )

    if len(markers) != 2:
        fail(f"expected exactly two phase markers, got {markers!r}")
    begin, end = markers
    if begin[1] != "BEGIN" or end[1] != "END":
        fail(f"markers are not one ordered BEGIN/END pair: {markers!r}")
    if begin[0] >= end[0]:
        fail(f"BEGIN must precede END: {markers!r}")
    if begin[2] != end[2]:
        fail(f"marker ids differ: {begin[2]!r} vs {end[2]!r}")
    if begin[3] != EXPECTED_EDIT_COUNT or end[3] != EXPECTED_EDIT_COUNT:
        fail(
            f"markers must declare edits={EXPECTED_EDIT_COUNT}: {markers!r}"
        )

    swiftui_lines = [
        (line_number, line, SWIFTUI_MESSAGE_PATTERN.search(line))
        for line_number, line in enumerate(lines, start=1)
        if "[SwiftUI]" in line or WARNING_MESSAGE in line
    ]
    unknown_lines = [
        (line_number, line)
        for line_number, line, match in swiftui_lines
        if match is None or match.group(1) != WARNING_MESSAGE
    ]
    if unknown_lines:
        fail(f"unexpected SwiftUI console diagnostics: {unknown_lines!r}")

    warning_lines = [
        (line_number, line)
        for line_number, line, match in swiftui_lines
        if match is not None and match.group(1) == WARNING_MESSAGE
    ]
    premeasure = [
        item for item in warning_lines if item[0] < begin[0]
    ]
    measured = [
        item for item in warning_lines if begin[0] < item[0] < end[0]
    ]
    postmeasure = [
        item for item in warning_lines if item[0] > end[0]
    ]

    if measured:
        fail(
            "known warning occurred during the five measured edits at lines "
            f"{[line_number for line_number, _ in measured]!r}"
        )
    if postmeasure:
        fail(
            "known warning occurred after the measured interval at lines "
            f"{[line_number for line_number, _ in postmeasure]!r}"
        )
    if len(premeasure) != EXPECTED_PREMEASURE_WARNING_COUNT:
        fail(
            "expected exactly "
            f"{EXPECTED_PREMEASURE_WARNING_COUNT} known warnings before BEGIN, "
            f"got {len(premeasure)} at lines "
            f"{[line_number for line_number, _ in premeasure]!r}"
        )
    if len(warning_lines) != EXPECTED_PREMEASURE_WARNING_COUNT:
        fail(
            "known raw warning total changed: "
            f"{len(warning_lines)} != {EXPECTED_PREMEASURE_WARNING_COUNT}"
        )

    budget_modes = [
        match.group(1)
        for line in lines
        if (match := BUDGET_MODE_PATTERN.search(line)) is not None
    ]
    expected_budget_modes = ["local-hard", "local-hard"]
    if budget_modes != expected_budget_modes:
        fail(
            "expected both F2 tests to report hard-local budget enforcement; "
            f"got {budget_modes!r}"
        )

    return (
        begin[2],
        len(premeasure),
        len(measured),
        len(postmeasure),
    )


def main() -> None:
    if len(sys.argv) != 5:
        fail(
            "usage: check-editor-find-f2-warning-phase.py "
            "LOG XCRESULT_INSPECTION_COPY EXPECTED_LOG_SHA256 "
            "EXPECTED_XCRESULT_SHA256"
        )

    log_path = Path(sys.argv[1])
    result_path = Path(sys.argv[2])
    expected_log_sha256 = sys.argv[3]
    expected_result_sha256 = sys.argv[4]
    if not log_path.is_file():
        fail(f"log file does not exist: {log_path}")
    if not result_path.is_dir():
        fail(f"xcresult bundle does not exist: {result_path}")

    validate_log_digest(log_path, expected_log_sha256)
    validate_artifact_digest(result_path, expected_result_sha256)
    phase_id, premeasure, measured, postmeasure = validate_log(log_path)
    coalesced_issue_count = validate_xcresult(load_xcresult_summary(result_path))
    print(
        "F2 WARNING CHECK PASS "
        f"id={phase_id} edits={EXPECTED_EDIT_COUNT} "
        f"raw-known-pre={premeasure} raw-known-measured={measured} "
        f"raw-known-post={postmeasure} unknown-swiftui=0 "
        f"raw-log-sha256={expected_log_sha256} "
        "budget-mode=local-hard budget-mode-markers=2 "
        f"xcresult-input-sha256={expected_result_sha256} "
        f"xcresult-coalesced-known={coalesced_issue_count}"
    )


if __name__ == "__main__":
    main()
