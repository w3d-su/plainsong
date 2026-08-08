from __future__ import annotations

from .context import Decimal, PROCESS_FILTER, SOURCE_COMMIT
from .core import (
    AuditError,
    parse_digest,
    parse_key_values,
    parse_rfc3339_utc,
    require,
    sha256_bytes,
)

def validate_run_boundary_capture(
    capture_path: Path,
    digest_path: Path,
    phase: str,
    run_id: str,
) -> datetime:
    data = capture_path.read_bytes()
    digest, byte_count = parse_digest(digest_path, f"{run_id} {phase} digest")
    require(
        digest == sha256_bytes(data) and byte_count == len(data),
        f"{run_id}: {phase} capture digest differs",
    )
    record = parse_key_values(
        capture_path,
        (
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
        ),
        f"{run_id} {phase}",
    )
    expected = {
        "format": "1",
        "phase": phase,
        "source_commit": SOURCE_COMMIT,
        "source_status": "clean",
        "process_filter": PROCESS_FILTER,
        "competing_process_lines": "0",
        "thermal_warning": "none",
        "power_source": "AC",
    }
    for key, value in expected.items():
        require(record[key] == value, f"{run_id}: {phase} {key} differs")
    timestamp = parse_rfc3339_utc(
        record["captured_utc"],
        f"{run_id}: {phase} captured_utc",
    )
    try:
        load_average = Decimal(record["load_average_1m"])
    except Exception as error:
        raise AuditError(f"{run_id}: {phase} load_average_1m is invalid") from error
    require(
        load_average.is_finite() and load_average >= Decimal("0"),
        f"{run_id}: {phase} load average is not finite and nonnegative: {load_average}",
    )
    return timestamp
