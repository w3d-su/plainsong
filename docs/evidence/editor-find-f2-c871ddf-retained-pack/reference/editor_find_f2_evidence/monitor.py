"""Validation for boundary, monitor, and outer-capture records."""

from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import datetime
from decimal import Decimal, InvalidOperation
from pathlib import Path, PurePosixPath

from .errors import AuditError, require
from .schema import EvidenceSchema
from .strict_io import parse_key_values, parse_utc, validate_digest


@dataclass(frozen=True)
class MonitorInterval:
    started: datetime
    first_sample_finished: datetime
    last_sample_started: datetime
    finished: datetime
    runner_pid: int


BOUNDARY_KEYS = (
    "format",
    "phase",
    "captured_utc",
    "source_commit",
    "source_status",
    "process_filter",
    "competing_process_lines",
    "load_average_1m",
    "thermal_warning",
    "power_source",
)


def validate_boundary(
    capture: Path,
    digest: Path,
    phase: str,
    schema: EvidenceSchema,
    label: str,
) -> datetime:
    validate_digest(capture, digest, label)
    record = parse_key_values(capture, BOUNDARY_KEYS, label)
    expected = {
        "format": "1",
        "phase": phase,
        "source_commit": schema.source_commit,
        "source_status": "clean",
        "process_filter": schema.process_filter,
        "competing_process_lines": "0",
        "thermal_warning": "none",
        "power_source": "AC",
    }
    for key, value in expected.items():
        require(record[key] == value, f"{label} {key} differs")
    try:
        load = Decimal(record["load_average_1m"])
    except InvalidOperation as error:
        raise AuditError(f"{label} load average is invalid") from error
    require(load.is_finite() and load >= 0, f"{label} load average is invalid")
    return parse_utc(record["captured_utc"], f"{label} captured_utc")


def _positive_integer(value: str, label: str) -> int:
    require(re.fullmatch(r"[0-9]+", value) is not None, f"{label} is not an integer")
    parsed = int(value)
    require(parsed > 0, f"{label} is not positive")
    return parsed


def validate_monitor(
    log: Path,
    log_digest: Path,
    samples: Path,
    samples_digest: Path,
    status: Path,
    status_digest: Path,
    expected_host: str,
    expected_capture_tooling_sha256: str,
    schema: EvidenceSchema,
    label: str,
) -> MonitorInterval:
    log_data = validate_digest(log, log_digest, f"{label} monitor log")
    require(log_data == b"", f"{label} captured a competing process")
    sample_data = validate_digest(samples, samples_digest, f"{label} monitor samples")
    validate_digest(status, status_digest, f"{label} monitor status")
    record = parse_key_values(status, schema.monitor_status_keys, f"{label} monitor status")
    require(record["format"] == str(schema.monitor_format), f"{label} monitor format differs")
    monitor_pid = _positive_integer(record["monitor_pid"], f"{label} monitor pid")
    runner_pid = _positive_integer(record["runner_pid"], f"{label} runner pid")
    require(monitor_pid != runner_pid, f"{label} monitor and runner PIDs match")
    started = parse_utc(record["started_utc"], f"{label} monitor start", True)
    first_finished = parse_utc(
        record["first_sample_finished_utc"], f"{label} first sample finish", True
    )
    last_started = parse_utc(
        record["last_sample_started_utc"], f"{label} last sample start", True
    )
    finished = parse_utc(record["finished_utc"], f"{label} monitor finish", True)
    require(started <= first_finished <= last_started <= finished, f"{label} monitor endpoints are unordered")
    require(record["sample_interval_ms"] == str(schema.monitor_interval_ms), f"{label} sample interval differs")
    require(record["match_count"] == "0" and record["exit_status"] == "0", f"{label} monitor did not pass")
    require(record["process_filter"] == schema.process_filter, f"{label} process filter differs")
    require(
        record["process_ownership_rule"] == schema.process_ownership_rule,
        f"{label} process ownership rule differs",
    )
    require(
        record["capture_tooling_sha256"] == expected_capture_tooling_sha256,
        f"{label} capture tooling hash differs",
    )
    require(record["allowed_host_executable"] == expected_host, f"{label} allowed host is not the exact frozen product")
    require(PurePosixPath(expected_host).is_absolute() and " " not in expected_host, f"{label} allowed host is invalid")

    try:
        sample_text = sample_data.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise AuditError(f"{label} monitor samples are not UTF-8") from error
    require(sample_text.endswith("\n"), f"{label} monitor samples must end with LF")
    pattern = re.compile(
        r"sequence=([0-9]+) started_utc=([^ ]+) finished_utc=([^ ]+) match_count=([0-9]+)"
    )
    parsed: list[tuple[datetime, datetime]] = []
    for sequence, line in enumerate(sample_text.splitlines(), start=1):
        match = pattern.fullmatch(line)
        require(match is not None, f"{label} monitor sample {sequence} is malformed")
        ordinal, start_text, finish_text, matches = match.groups()
        require(int(ordinal) == sequence and matches == "0", f"{label} monitor sample {sequence} differs")
        sample_start = parse_utc(start_text, f"{label} sample start", True)
        sample_finish = parse_utc(finish_text, f"{label} sample finish", True)
        duration = Decimal(str((sample_finish - sample_start).total_seconds())) * 1000
        require(0 <= duration <= schema.monitor_max_gap_ms, f"{label} sample inspection gap exceeds limit")
        if parsed:
            gap = Decimal(str((sample_start - parsed[-1][1]).total_seconds())) * 1000
            require(0 <= gap <= schema.monitor_max_gap_ms, f"{label} sampling gap exceeds limit")
        parsed.append((sample_start, sample_finish))
    sample_count = _positive_integer(record["sample_count"], f"{label} sample count")
    require(len(parsed) == sample_count, f"{label} sample count differs")
    require(parsed[0] == (started, first_finished), f"{label} first sample endpoint differs")
    require(parsed[-1] == (last_started, finished), f"{label} last sample endpoint differs")
    return MonitorInterval(started, first_finished, last_started, finished, runner_pid)


def validate_outer(path: Path, schema: EvidenceSchema, label: str) -> None:
    record = parse_key_values(path, schema.outer_status_keys, label)
    expected = {
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
    for key, value in expected.items():
        require(record[key] == value, f"{label} {key} differs")
