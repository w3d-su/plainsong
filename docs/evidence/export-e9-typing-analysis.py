"""Reported-only analyses of an E9 typing-isolation run log.

Reads the `E9 TYPING JSON` lines that
`AppBackedEditorPerformanceTests/testTypingStaysIsolatedFromActiveHTMLAndPDFExport` prints
(`Scripts/run-export-html-e9.sh --typing Debug|Release` writes them to `run.log`) and prints,
per product:

- paired: each keystroke during the export minus the no-export keystroke at the same burst
  position in the same round, with a 95% cluster bootstrap interval (rounds resampled) on
  the median difference. Export keystrokes past position 29 have no partner.
- idle: the no-export burst's first keystroke against its keystrokes 1-9, by the idle time
  before the burst (the offset plus the 500 ms pause between arms).

None of this gates; `docs/perf/2026-11-18-export-e9-typing-isolation.md` defines the gates.
Usage: python3 -I export-e9-typing-analysis.py <run.log>
"""

import json
import math
import random
import statistics
import sys

PREFIX = "E9 TYPING JSON "
PAUSE_MILLISECONDS = 500
RESAMPLES = 10000
SEED = 20261118


def reports(path):
    with open(path, encoding="utf-8", errors="replace") as stream:
        for line in stream:
            if line.startswith(PREFIX):
                yield json.loads(line[len(PREFIX):])


def paired(report):
    per_round = []
    unpaired = 0
    for rnd in report["rounds"]:
        baseline = {s["position"]: s["handlerMilliseconds"] for s in rnd["withoutExport"]}
        differences = []
        for sample in rnd["exportArm"]:
            if not sample["duringExport"]:
                continue
            if sample["position"] in baseline:
                differences.append(sample["handlerMilliseconds"] - baseline[sample["position"]])
            else:
                unpaired += 1
        per_round.append(differences)
    pooled = [d for differences in per_round for d in differences]
    if not pooled:
        return "no pairs"
    generator = random.Random(SEED)
    medians = []
    while len(medians) < RESAMPLES:
        chosen = [per_round[generator.randrange(len(per_round))] for _ in per_round]
        sample = [d for differences in chosen for d in differences]
        if sample:
            medians.append(statistics.median(sample))
    medians.sort()
    # Nearest rank, as the probe's Swift statistics compute it.
    lower = medians[math.ceil(0.025 * RESAMPLES) - 1]
    upper = medians[math.ceil(0.975 * RESAMPLES) - 1]
    return (
        f"n={len(pooled)} median {statistics.median(pooled):+.3f} ms "
        f"[{lower:+.3f}, {upper:+.3f}], {unpaired} later export keystrokes unpaired"
    )


def idle(report):
    by_offset = {}
    for rnd in report["rounds"]:
        burst = rnd["withoutExport"]
        by_offset.setdefault(round(rnd["offsetMilliseconds"]), []).append(
            (burst[0]["handlerMilliseconds"], statistics.median(s["handlerMilliseconds"] for s in burst[1:10]))
        )
    return [
        f"idle {offset + PAUSE_MILLISECONDS} ms: first {statistics.median(v[0] for v in values):.1f}, "
        f"keystrokes 1-9 {statistics.median(v[1] for v in values):.1f} ms ({len(values)} rounds)"
        for offset, values in sorted(by_offset.items())
    ]


def main(path):
    for report in reports(path):
        summary = report["summary"]
        name = f"{summary['product']} {summary['configuration']}"
        print(f"{name} paired: {paired(report)}")
        for line in idle(report):
            print(f"{name} {line}")


if __name__ == "__main__":
    main(sys.argv[1])
