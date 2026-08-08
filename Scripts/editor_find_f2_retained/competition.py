from __future__ import annotations

from .context import (
    MONITOR_MAX_SAMPLE_GAP_MILLISECONDS,
    MONITOR_SAMPLE_INTERVAL_MILLISECONDS,
    MONITOR_STATUS_KEYS,
    PROCESS_FILTER,
    PROCESS_OWNERSHIP_RULE,
    Decimal,
    PurePosixPath,
    base64,
    hashlib,
    re,
)
from .core import (
    AuditError,
    parse_decimal_integer,
    parse_digest,
    parse_key_values,
    parse_rfc3339_utc,
    require,
    sha256_bytes,
)

def validate_competition_monitor(
    log_path: Path,
    log_digest_path: Path,
    samples_path: Path,
    samples_digest_path: Path,
    run_owned_path: Path,
    run_owned_digest_path: Path,
    status_path: Path,
    status_digest_path: Path,
    run_id: str,
    configuration: str,
) -> dict[str, object]:
    log_data = log_path.read_bytes()
    log_sha, log_bytes = parse_digest(
        log_digest_path,
        f"{run_id} competition-monitor digest",
    )
    require(
        log_data == b""
        and log_bytes == 0
        and log_sha == hashlib.sha256(b"").hexdigest(),
        f"{run_id}: a competing Xcode/Swift/XCTest/Plainsong process was captured",
    )

    samples_data = samples_path.read_bytes()
    samples_sha, samples_bytes = parse_digest(
        samples_digest_path,
        f"{run_id} competition-monitor samples digest",
    )
    require(
        samples_sha == sha256_bytes(samples_data) and samples_bytes == len(samples_data),
        f"{run_id}: competition-monitor samples digest differs",
    )
    try:
        samples_text = samples_data.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise AuditError(
            f"{run_id}: competition-monitor samples are not UTF-8: {error}"
        ) from error
    require(samples_text.endswith("\n"), f"{run_id}: monitor samples must end with LF")

    status_data = status_path.read_bytes()
    status_sha, status_bytes = parse_digest(
        status_digest_path,
        f"{run_id} competition-monitor status digest",
    )
    require(
        status_sha == sha256_bytes(status_data) and status_bytes == len(status_data),
        f"{run_id}: competition-monitor status digest differs",
    )
    record = parse_key_values(
        status_path,
        MONITOR_STATUS_KEYS,
        f"{run_id} competition-monitor status",
    )
    require(record["format"] == "4", f"{run_id}: competition-monitor format differs")
    monitor_pid = parse_decimal_integer(
        record["monitor_pid"],
        f"{run_id} competition-monitor pid",
        positive=True,
    )
    runner_pid = parse_decimal_integer(
        record["runner_pid"],
        f"{run_id} authoritative runner pid",
        positive=True,
    )
    require(
        runner_pid != monitor_pid,
        f"{run_id}: monitor and authoritative runner PIDs must differ",
    )
    started = parse_rfc3339_utc(
        record["started_utc"],
        f"{run_id}: competition-monitor started_utc",
        require_fraction=True,
    )
    finished = parse_rfc3339_utc(
        record["finished_utc"],
        f"{run_id}: competition-monitor finished_utc",
        require_fraction=True,
    )
    first_sample_finished = parse_rfc3339_utc(
        record["first_sample_finished_utc"],
        f"{run_id}: competition-monitor first_sample_finished_utc",
        require_fraction=True,
    )
    last_sample_started = parse_rfc3339_utc(
        record["last_sample_started_utc"],
        f"{run_id}: competition-monitor last_sample_started_utc",
        require_fraction=True,
    )
    require(finished > started, f"{run_id}: competition-monitor did not have a positive interval")
    require(
        started <= first_sample_finished <= last_sample_started <= finished,
        f"{run_id}: competition-monitor sample endpoints are out of order",
    )
    require(
        record["sample_interval_ms"] == str(MONITOR_SAMPLE_INTERVAL_MILLISECONDS),
        f"{run_id}: competition-monitor sample interval is not 200 ms",
    )
    sample_count = parse_decimal_integer(
        record["sample_count"],
        f"{run_id} competition-monitor sample count",
        positive=True,
    )
    run_owned_count = parse_decimal_integer(
        record["run_owned_process_records"],
        f"{run_id} run-owned process record count",
    )
    runner_finished_sequence = parse_decimal_integer(
        record["runner_finished_before_sequence"],
        f"{run_id} runner-finished sequence",
        positive=True,
    )
    sample_pattern = re.compile(
        r"sequence=([0-9]+) "
        r"started_utc=([^ ]+) "
        r"finished_utc=([^ ]+) "
        r"match_count=([0-9]+)"
    )
    parsed_samples: list[tuple[datetime, datetime]] = []
    for expected_sequence, line in enumerate(samples_text.splitlines(), start=1):
        match = sample_pattern.fullmatch(line)
        require(match is not None, f"{run_id}: malformed monitor sample {expected_sequence}")
        sequence, sample_started_text, sample_finished_text, matches = match.groups()
        require(int(sequence) == expected_sequence, f"{run_id}: monitor sample sequence differs")
        require(matches == "0", f"{run_id}: monitor sample observed a competing process")
        sample_started = parse_rfc3339_utc(
            sample_started_text,
            f"{run_id}: monitor sample {expected_sequence} start",
            require_fraction=True,
        )
        sample_finished = parse_rfc3339_utc(
            sample_finished_text,
            f"{run_id}: monitor sample {expected_sequence} finish",
            require_fraction=True,
        )
        require(sample_finished >= sample_started, f"{run_id}: monitor sample interval is negative")
        sample_duration_milliseconds = Decimal(
            str((sample_finished - sample_started).total_seconds())
        ) * Decimal(1000)
        require(
            sample_duration_milliseconds <= Decimal(MONITOR_MAX_SAMPLE_GAP_MILLISECONDS),
            f"{run_id}: monitor sample inspection exceeds one second",
        )
        if parsed_samples:
            previous_finished = parsed_samples[-1][1]
            gap_milliseconds = Decimal(
                str((sample_started - previous_finished).total_seconds())
            ) * Decimal(1000)
            require(gap_milliseconds >= 0, f"{run_id}: monitor samples overlap")
            require(
                gap_milliseconds <= Decimal(MONITOR_MAX_SAMPLE_GAP_MILLISECONDS),
                f"{run_id}: monitor sampling gap exceeds one second",
            )
        parsed_samples.append((sample_started, sample_finished))
    require(len(parsed_samples) == sample_count, f"{run_id}: monitor sample count differs")
    require(
        parsed_samples[0] == (started, first_sample_finished)
        and parsed_samples[-1] == (last_sample_started, finished),
        f"{run_id}: monitor status endpoints differ from retained samples",
    )
    require(record["match_count"] == "0", f"{run_id}: competition-monitor match count is not zero")
    require(record["process_filter"] == PROCESS_FILTER, f"{run_id}: competition-monitor filter differs")
    require(
        record["process_ownership_rule"] == PROCESS_OWNERSHIP_RULE,
        f"{run_id}: competition-monitor ownership rule differs",
    )
    correlation_output_prefix = record["correlation_output_prefix"]
    require(
        PurePosixPath(correlation_output_prefix).is_absolute()
        and correlation_output_prefix == record["allowed_run_prefix"],
        f"{run_id}: competition-monitor correlation prefix differs",
    )
    expected_host_executable = (
        f"{correlation_output_prefix}.products/Build/Products/{configuration}/"
        "Plainsong.app/Contents/MacOS/Plainsong"
    )
    require(
        record["allowed_host_executable"] == expected_host_executable,
        f"{run_id}: competition-monitor host executable differs",
    )
    require(
        PurePosixPath(record["allowed_run_prefix"]).is_absolute(),
        f"{run_id}: competition-monitor allowed prefix is not absolute",
    )

    run_owned_data = run_owned_path.read_bytes()
    run_owned_sha, run_owned_bytes = parse_digest(
        run_owned_digest_path,
        f"{run_id} run-owned process digest",
    )
    require(
        run_owned_sha == sha256_bytes(run_owned_data)
        and run_owned_bytes == len(run_owned_data),
        f"{run_id}: run-owned process digest differs",
    )
    try:
        run_owned_text = run_owned_data.decode("ascii", errors="strict")
    except UnicodeDecodeError as error:
        raise AuditError(
            f"{run_id}: run-owned process log is not ASCII: {error}"
        ) from error
    require(
        run_owned_text == "" or run_owned_text.endswith("\n"),
        f"{run_id}: run-owned process log must be empty or end with LF",
    )
    owned_pattern = re.compile(
        r"sequence=([0-9]+) "
        r"sample_started_utc=([^ ]+) "
        r"pid=([0-9]+) "
        r"ppid=([0-9]+) "
        r"pgid=([0-9]+) "
        r"reason=(exact-host-executable|exact-host-exited-before-command-capture|"
        r"output-prefix-command-token) "
        r"executable_base64=([^ ]+) "
        r"matched_token_base64=([^ ]+) "
        r"command_base64=([^ ]+)"
    )
    target_names = frozenset(PROCESS_FILTER.split("|"))

    def decode_owned_field(value: str, field: str, line_number: int) -> str:
        try:
            decoded = base64.b64decode(value, validate=True).decode(
                "utf-8", errors="strict"
            )
        except (ValueError, UnicodeDecodeError) as error:
            raise AuditError(
                f"{run_id}: run-owned line {line_number} has invalid {field}"
            ) from error
        require(
            decoded != "" and not any(character in decoded for character in "\x00\r\n\t"),
            f"{run_id}: run-owned line {line_number} has unsafe {field}",
        )
        return decoded

    owned_lines = run_owned_text.splitlines()
    require(
        len(owned_lines) == run_owned_count,
        f"{run_id}: run-owned process count differs",
    )
    require(
        runner_finished_sequence <= sample_count,
        f"{run_id}: runner-finished sequence is outside retained samples",
    )
    runner_finished_sample_started = parsed_samples[runner_finished_sequence - 1][0]
    for line_number, line in enumerate(owned_lines, start=1):
        owned_match = owned_pattern.fullmatch(line)
        require(
            owned_match is not None,
            f"{run_id}: malformed run-owned process line {line_number}",
        )
        (
            sequence_text,
            sample_started_text,
            pid_text,
            ppid_text,
            pgid_text,
            reason,
            executable_base64,
            matched_token_base64,
            command_base64,
        ) = owned_match.groups()
        sequence = parse_decimal_integer(
            sequence_text,
            f"{run_id} run-owned line {line_number} sequence",
            positive=True,
        )
        require(
            sequence < runner_finished_sequence,
            f"{run_id}: run-owned process was exempted after the runner finished",
        )
        require(
            parse_rfc3339_utc(
                sample_started_text,
                f"{run_id}: run-owned line {line_number} sample time",
                require_fraction=True,
            )
            == parsed_samples[sequence - 1][0],
            f"{run_id}: run-owned process sample time differs",
        )
        parse_decimal_integer(
            pid_text,
            f"{run_id} run-owned line {line_number} pid",
            positive=True,
        )
        parse_decimal_integer(
            ppid_text,
            f"{run_id} run-owned line {line_number} ppid",
        )
        parse_decimal_integer(
            pgid_text,
            f"{run_id} run-owned line {line_number} pgid",
            positive=True,
        )
        executable = decode_owned_field(
            executable_base64, "executable", line_number
        )
        matched_token = decode_owned_field(
            matched_token_base64, "matched token", line_number
        )
        command = decode_owned_field(command_base64, "command", line_number)
        require(
            PurePosixPath(executable).name in target_names,
            f"{run_id}: run-owned line {line_number} is not a monitored executable",
        )
        if reason == "exact-host-exited-before-command-capture":
            require(
                executable == expected_host_executable
                and matched_token == expected_host_executable
                and command == "<exited-before-command-capture>",
                f"{run_id}: run-owned line {line_number} exited-host identity differs",
            )
        elif reason == "exact-host-executable":
            require(
                executable == expected_host_executable
                and matched_token == expected_host_executable
                and matched_token in command.split(),
                f"{run_id}: run-owned line {line_number} host identity differs",
            )
        else:
            require(
                matched_token in command.split()
                and (
                    matched_token == correlation_output_prefix
                    or matched_token.startswith(correlation_output_prefix + ".")
                    or matched_token.startswith(correlation_output_prefix + "/")
                ),
                f"{run_id}: run-owned line {line_number} lacks an exact prefix boundary",
            )
    require(record["exit_status"] == "0", f"{run_id}: competition-monitor did not exit zero")
    return {
        "pid": monitor_pid,
        "runnerPid": runner_pid,
        "started": started,
        "finished": finished,
        "firstSampleFinished": first_sample_finished,
        "lastSampleStarted": last_sample_started,
        "sampleCount": sample_count,
        "runOwnedProcessRecords": run_owned_count,
        "runnerFinishedBeforeSequence": runner_finished_sequence,
        "runnerFinishedSampleStarted": runner_finished_sample_started,
        "allowedRunPrefix": record["allowed_run_prefix"],
    }
