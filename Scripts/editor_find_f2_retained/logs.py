from __future__ import annotations

from .context import (
    BUDGET_MODE_RE,
    EXPECTED_BUDGETS,
    EXPECTED_TESTS,
    HOST_RE,
    MARKER_RE,
    QUERY_RE,
    SWIFTUI_RE,
    WARNING_MESSAGE,
    Decimal,
    datetime,
    re,
    timezone,
)
from .core import AuditError, require

def parse_tokens(line: str, prefix: str, keys: tuple[str, ...], label: str) -> dict[str, str]:
    require(line.startswith(prefix + " "), f"{label} has the wrong prefix")
    result: dict[str, str] = {}
    order: list[str] = []
    for token in line[len(prefix) + 1 :].split(" "):
        require(token != "" and "=" in token, f"invalid {label} token: {token!r}")
        key, value = token.split("=", 1)
        require(key not in result and value != "", f"invalid duplicate/empty {label} token: {key}")
        result[key] = value
        order.append(key)
    require(tuple(order) == keys, f"{label} token order differs: {order!r}")
    return result


def decimal_samples(match: re.Match, names: tuple[str, ...], label: str) -> list[Decimal]:
    samples = [Decimal(match.group(name)) for name in names]
    require(all(value > 0 and value.is_finite() for value in samples), f"invalid {label} samples")
    return samples


def odd_median(values: list[Decimal]) -> Decimal:
    ordered = sorted(values)
    return ordered[len(ordered) // 2]


def validate_warning_phase(text: str) -> dict[str, object]:
    lines = text.splitlines()
    markers: list[tuple[int, str, str, int]] = []
    for index, line in enumerate(lines):
        for match in MARKER_RE.finditer(line):
            markers.append((index, match.group(1), match.group(2), int(match.group(3))))
    require(len(markers) == 2, f"expected exactly two warning markers, got {markers!r}")
    begin, end = markers
    require(begin[1] == "BEGIN" and end[1] == "END", "warning markers are not BEGIN/END")
    require(begin[0] < end[0], "warning BEGIN does not precede END")
    require(begin[2] == end[2], "warning marker UUIDs differ")
    require(begin[3] == 5 and end[3] == 5, "warning markers must declare edits=5")

    diagnostics = []
    for index, line in enumerate(lines):
        if "[SwiftUI]" in line or WARNING_MESSAGE in line:
            diagnostics.append((index, line, SWIFTUI_RE.search(line)))
    unknown = [
        (index + 1, line)
        for index, line, match in diagnostics
        if match is None or match.group(1) != WARNING_MESSAGE
    ]
    require(not unknown, f"unexpected SwiftUI diagnostics: {unknown!r}")
    warnings = [
        (index, line)
        for index, line, match in diagnostics
        if match is not None and match.group(1) == WARNING_MESSAGE
    ]
    pre = [item for item in warnings if item[0] < begin[0]]
    measured = [item for item in warnings if begin[0] < item[0] < end[0]]
    post = [item for item in warnings if item[0] > end[0]]
    require(
        not measured,
        "known warning occurred during the five measured edits at lines "
        f"{[index + 1 for index, _ in measured]!r}",
    )
    require(
        not post,
        f"known warning occurred after the measured interval at lines "
        f"{[index + 1 for index, _ in post]!r}",
    )
    require(len(pre) == 3, f"expected exactly three pre-measure warnings, got {len(pre)}")
    require(len(warnings) == 3, f"known raw warning total changed: {len(warnings)}")
    budget_modes = [
        match.group(1)
        for line in lines
        if (match := BUDGET_MODE_RE.search(line)) is not None
    ]
    require(budget_modes == ["local-hard", "local-hard"], f"budget markers differ: {budget_modes!r}")
    return {
        "id": begin[2],
        "pre": len(pre),
        "measured": len(measured),
        "post": len(post),
        "beginIndex": begin[0],
        "warningIndices": [index for index, _ in warnings],
    }


def validate_warning_negative_control(text: str) -> None:
    phase = validate_warning_phase(text)
    lines = text.splitlines(keepends=True)
    warning_index = phase["warningIndices"][0]
    begin_index = phase["beginIndex"]
    moved = lines.pop(warning_index)
    if warning_index < begin_index:
        begin_index -= 1
    lines.insert(begin_index + 1, moved)
    try:
        validate_warning_phase("".join(lines))
    except AuditError as error:
        require(
            str(error).startswith("known warning occurred during the five measured edits"),
            f"warning negative control failed for the wrong reason: {error}",
        )
        return
    raise AuditError("warning negative control unexpectedly passed")


def extract_timings(text: str, run_id: str) -> dict[str, Decimal]:
    lines = text.splitlines()
    query_lines = [line for line in lines if "F2 PERF find query " in line]
    require(len(query_lines) == 3, f"{run_id}: expected three query timing lines")
    metrics: dict[str, Decimal] = {}
    seen_labels: set[str] = set()
    shapes = {
        "zero": (0, "false", "zeroQueryCompletion"),
        "sparse": (1, "false", "sparseQueryCompletion"),
        "dense-truncated": (10_000, "true", "denseTruncatedQueryCompletion"),
    }
    for line in query_lines:
        match = QUERY_RE.search(line)
        require(match is not None, f"{run_id}: malformed query timing line: {line!r}")
        label = match.group("label")
        require(label not in seen_labels, f"{run_id}: duplicate query timing for {label}")
        seen_labels.add(label)
        expected_count, expected_truncation, metric = shapes[label]
        require(int(match.group("count")) == expected_count, f"{run_id}: {label} count changed")
        require(match.group("truncated") == expected_truncation, f"{run_id}: {label} truncation changed")
        samples = decimal_samples(match, ("s1", "s2", "s3"), f"{run_id} {label}")
        median = Decimal(match.group("median"))
        require(median == odd_median(samples), f"{run_id}: {label} printed median is wrong")
        require(median < EXPECTED_BUDGETS[metric], f"{run_id}: {label} median exceeds budget")
        metrics[metric] = median

    host_lines = [line for line in lines if "F2 PERF production WorkspaceWindow find-open edit" in line]
    require(len(host_lines) == 1, f"{run_id}: expected one hosted timing line")
    host = HOST_RE.search(host_lines[0])
    require(host is not None, f"{run_id}: malformed hosted timing line")
    admission = decimal_samples(host, ("a1", "a2", "a3", "a4", "a5"), f"{run_id} admission")
    receipt = decimal_samples(host, ("r1", "r2", "r3", "r4", "r5"), f"{run_id} receipt")
    admission_median = Decimal(host.group("admission_median"))
    receipt_median = Decimal(host.group("receipt_median"))
    receipt_maximum = Decimal(host.group("receipt_max"))
    require(admission_median == odd_median(admission), f"{run_id}: admission median is wrong")
    require(receipt_median == odd_median(receipt), f"{run_id}: receipt median is wrong")
    require(receipt_maximum == max(receipt), f"{run_id}: receipt maximum is wrong")
    require(
        admission_median < EXPECTED_BUDGETS["nativeEditAdmission"],
        f"{run_id}: admission median exceeds budget",
    )
    require(
        receipt_median < EXPECTED_BUDGETS["rootStateUpdateReceipt"],
        f"{run_id}: receipt median exceeds budget",
    )
    metrics["nativeEditAdmission"] = admission_median
    metrics["rootStateUpdateReceipt"] = receipt_median
    metrics["rootStateUpdateReceiptMaximum"] = receipt_maximum

    require(text.count("** TEST EXECUTE SUCCEEDED **") == 1, f"{run_id}: missing unique test success marker")
    require("** TEST EXECUTE FAILED **" not in text, f"{run_id}: raw log reports test failure")
    require(re.search(r"F2 PERF .* exceeded .* budget", text) is None, f"{run_id}: raw log reports budget failure")
    for test_name in EXPECTED_TESTS:
        passed = [
            line
            for line in lines
            if test_name in line and re.search(r"\bpassed \([0-9.]+ seconds\)\.?$", line)
        ]
        require(len(passed) == 1, f"{run_id}: expected one passed line for {test_name}")
    return metrics


def parse_summary_timestamp(value: object, label: str) -> datetime:
    require(
        isinstance(value, (int, float)) and not isinstance(value, bool),
        f"{label} is not a numeric Unix timestamp",
    )
    try:
        require(Decimal(str(value)).is_finite() and value >= 0, f"{label} is invalid")
        return datetime.fromtimestamp(value, timezone.utc)
    except (OverflowError, OSError, ValueError) as error:
        raise AuditError(f"{label} is not a valid Unix timestamp: {error}") from error


def validate_summary(summary: object, environment: dict, label: str) -> None:
    require(isinstance(summary, dict), f"{label} must be an object")
    expected_counts = {
        "result": "Passed",
        "passedTests": 2,
        "failedTests": 0,
        "skippedTests": 0,
        "expectedFailures": 0,
        "totalTestCount": 2,
    }
    for key, expected in expected_counts.items():
        require(summary.get(key) == expected, f"{label} {key} is {summary.get(key)!r}, expected {expected!r}")
    require(summary.get("testFailures") == [], f"{label} testFailures must be empty")
    warnings = summary.get("runtimeWarnings")
    require(isinstance(warnings, list) and len(warnings) == 1, f"{label} must have one coalesced warning")
    warning = warnings[0]
    require(isinstance(warning, dict), f"{label} warning must be an object")
    require(warning.get("message") == WARNING_MESSAGE, f"{label} warning message changed")
    require(warning.get("issueType") == "Runtime Warning", f"{label} warning issueType changed")

    configurations = summary.get("devicesAndConfigurations")
    require(isinstance(configurations, list) and len(configurations) == 1, f"{label} must have one device/configuration")
    configuration = configurations[0]
    require(isinstance(configuration, dict), f"{label} device/configuration must be an object")
    for key in ("passedTests", "failedTests", "skippedTests", "expectedFailures"):
        require(configuration.get(key) == expected_counts[key], f"{label} configuration {key} changed")
    require(
        configuration.get("passedTests", 0)
        + configuration.get("failedTests", 0)
        + configuration.get("skippedTests", 0)
        == 2,
        f"{label} configuration test total changed",
    )
    device = configuration.get("device")
    require(isinstance(device, dict), f"{label} device is missing")
    require(device.get("architecture") == environment["architecture"], f"{label} architecture changed")
    require(device.get("platform") == "macOS", f"{label} platform is not macOS")
    require(device.get("osVersion") == environment["macOSVersion"], f"{label} macOS version differs")
    require(device.get("osBuildNumber") == environment["macOSBuild"], f"{label} macOS build differs")
