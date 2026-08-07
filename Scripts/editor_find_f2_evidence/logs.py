"""Independent warning-phase and timing validation from retained raw logs."""

from __future__ import annotations

import re
from decimal import Decimal

from .errors import AuditError, require

WARNING = "Modifying state during view update, this will cause undefined behavior."
MARKER = re.compile(
    r"F2_WARNING_PHASE_(BEGIN|END) id=([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}) edits=([0-9]+)\s*$"
)
SWIFTUI = re.compile(r"\[SwiftUI\] (.+?)\s*$")
D3 = r"[0-9]+\.[0-9]{3}"
QUERY = re.compile(
    rf"F2 PERF find query (?P<label>zero|sparse|dense-truncated) 1MB median (?P<median>{D3}) ms "
    rf"samples \[(?P<a>{D3}), (?P<b>{D3}), (?P<c>{D3})\] \((?P<count>0|1|10000) retained, "
    r"truncated=(?P<truncated>true|false)\)$"
)
HOST = re.compile(
    rf"F2 PERF production WorkspaceWindow find-open edit 1MB admission median (?P<am>{D3}) ms "
    rf"samples \[(?P<a1>{D3}), (?P<a2>{D3}), (?P<a3>{D3}), (?P<a4>{D3}), (?P<a5>{D3})\]; "
    rf"state-update receipt median (?P<rm>{D3}) ms max (?P<rx>{D3}) ms samples "
    rf"\[(?P<r1>{D3}), (?P<r2>{D3}), (?P<r3>{D3}), (?P<r4>{D3}), (?P<r5>{D3})\]$"
)
BUDGETS = {
    "zero": Decimal("400"),
    "sparse": Decimal("400"),
    "dense-truncated": Decimal("1100"),
    "admission": Decimal("5"),
    "receipt": Decimal("15"),
}


def _median(values: list[Decimal]) -> Decimal:
    return sorted(values)[len(values) // 2]


def validate_warning_phase(text: str) -> dict[str, object]:
    lines = text.splitlines()
    markers = [(index, match) for index, line in enumerate(lines) if (match := MARKER.search(line))]
    require(len(markers) == 2, "expected exactly one warning BEGIN/END pair")
    begin_index, begin = markers[0]
    end_index, end = markers[1]
    require(begin.group(1) == "BEGIN" and end.group(1) == "END", "warning markers are unordered")
    require(begin_index < end_index and begin.group(2) == end.group(2), "warning marker identity differs")
    require(begin.group(3) == end.group(3) == "5", "warning markers must declare five edits")
    diagnostics: list[tuple[int, str]] = []
    for index, line in enumerate(lines):
        if "[SwiftUI]" in line or WARNING in line:
            match = SWIFTUI.search(line)
            require(match is not None and match.group(1) == WARNING, f"unexpected SwiftUI diagnostic at line {index + 1}")
            diagnostics.append((index, line))
    pre = [item for item in diagnostics if item[0] < begin_index]
    measured = [item for item in diagnostics if begin_index < item[0] < end_index]
    post = [item for item in diagnostics if item[0] > end_index]
    require(not measured, "known warning occurred during the measured edits")
    require(not post, "known warning occurred after the measured edits")
    require(len(pre) == 3, f"expected three pre-measure warnings, got {len(pre)}")
    modes = [match.group(1) for line in lines if (match := re.search(r"F2 PERF budget mode (local-hard|ci-informational)$", line))]
    require(modes == ["local-hard", "local-hard"], f"budget markers differ: {modes}")
    return {"begin": begin_index, "warning": pre[0][0], "id": begin.group(2)}


def validate_warning_negative_control(text: str) -> None:
    phase = validate_warning_phase(text)
    lines = text.splitlines(keepends=True)
    warning = lines.pop(int(phase["warning"]))
    begin = int(phase["begin"]) - 1
    lines.insert(begin + 1, warning)
    try:
        validate_warning_phase("".join(lines))
    except AuditError as error:
        require("during the measured edits" in str(error), f"warning control failed for wrong reason: {error}")
        return
    raise AuditError("warning placement negative control unexpectedly passed")


def validate_timings(text: str, label: str) -> dict[str, Decimal]:
    query_lines = [line for line in text.splitlines() if "F2 PERF find query " in line]
    require(len(query_lines) == 3, f"{label} must contain three query timing lines")
    shapes = {"zero": (0, "false"), "sparse": (1, "false"), "dense-truncated": (10000, "true")}
    result: dict[str, Decimal] = {}
    for line in query_lines:
        match = QUERY.search(line)
        require(match is not None, f"{label} malformed query timing")
        name = match.group("label")
        require(name not in result, f"{label} duplicate query timing")
        count, truncated = shapes[name]
        require(int(match.group("count")) == count and match.group("truncated") == truncated, f"{label} query shape differs")
        samples = [Decimal(match.group(key)) for key in ("a", "b", "c")]
        median = Decimal(match.group("median"))
        require(median == _median(samples) and median < BUDGETS[name], f"{label} query median invalid")
        result[name] = median
    host_lines = [line for line in text.splitlines() if "F2 PERF production WorkspaceWindow" in line]
    require(len(host_lines) == 1, f"{label} must contain one hosted timing line")
    host = HOST.search(host_lines[0])
    require(host is not None, f"{label} malformed hosted timing")
    admission = [Decimal(host.group(f"a{index}")) for index in range(1, 6)]
    receipt = [Decimal(host.group(f"r{index}")) for index in range(1, 6)]
    require(Decimal(host.group("am")) == _median(admission) < BUDGETS["admission"], f"{label} admission invalid")
    require(Decimal(host.group("rm")) == _median(receipt) < BUDGETS["receipt"], f"{label} receipt invalid")
    require(Decimal(host.group("rx")) == max(receipt), f"{label} receipt maximum invalid")
    require(text.count("** TEST EXECUTE SUCCEEDED **") == 1 and "** TEST EXECUTE FAILED **" not in text, f"{label} test status invalid")
    return result
