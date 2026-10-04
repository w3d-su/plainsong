"""Handoff 21: prebuilt, two-product paired typing comparison under recorded load.

Creates evidence only. Never generates, builds, edits a worktree, or changes Git state.
Statistics and admission snapshots reuse the committed Handoff 22 helper.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import time

sys.dont_write_bytecode = True

BASELINE_SHA = "91f0ebaca7b15d8b0994ba9ac6cf0f89016f3a75"
DEFAULT_BASELINE = "/private/tmp/plainsong-h21-baseline"
DEFAULT_CANDIDATE = "/Users/davis._.su/Documents/plainsong-reconciled-presentation"
DEFAULT_LOCK = "/private/tmp/plainsong-xcodebuild-test.lock"
TESTS = (
    "PlainsongTests/EditorFindHostedGateTests/testHostedLargeFixtureSourceOnlyTypingStaysUnderBudget",
    "PlainsongTests/EditorFindHostedGateTests/testHostedLargeFixtureWYSIWYGTypingStaysUnderBudget",
)


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def command(args, cwd=None):
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def content_fingerprint(root):
    """Hash exact working contents, including untracked files and deleted tracked paths."""
    root = Path(root)
    paths = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=root
    ).split(b"\0")
    manifest = []
    for raw_path in sorted(set(paths) - {b""}):
        relative = os.fsdecode(raw_path)
        path = root / relative
        if path.is_symlink():
            payload, kind = os.fsencode(os.readlink(path)), "symlink"
        elif path.is_file():
            payload, kind = path.read_bytes(), "file"
        elif not path.exists():
            payload, kind = b"", "deleted"
        else:
            raise RuntimeError("Unsupported Git path for fingerprint: " + str(path))
        manifest.append({"path": relative, "kind": kind, "sha256": hashlib.sha256(payload).hexdigest()})
    canonical = json.dumps(manifest, sort_keys=True, separators=(",", ":")).encode()
    return {
        "root": str(root),
        "head": command(["git", "rev-parse", "HEAD"], root),
        "status": command(["git", "status", "--porcelain=v1", "--untracked-files=all"], root),
        "content_sha256": hashlib.sha256(canonical).hexdigest(),
        "manifest": manifest,
    }


def parse_arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-root", default=DEFAULT_BASELINE)
    parser.add_argument("--candidate-root", default=DEFAULT_CANDIDATE)
    parser.add_argument("--baseline-derived-data", required=True)
    parser.add_argument("--candidate-derived-data", required=True)
    parser.add_argument("--candidate-sha", required=True, help="Exact implementation commit that was prebuilt")
    parser.add_argument("--evidence-dir", required=True, help="New directory under /private/tmp")
    parser.add_argument("--lock", default=os.environ.get("PLAINSONG_XCODEBUILD_LOCK", DEFAULT_LOCK))
    parser.add_argument("--pairs", type=int, default=10)
    parser.add_argument("--max-load", type=float, default=6.0)
    parser.add_argument("--wait-seconds", type=int, default=300)
    parser.add_argument("--batch-product", choices=("baseline", "candidate"), help=argparse.SUPPRESS)
    parser.add_argument("--batch-iteration", type=int, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.pairs != 10 or args.max_load != 6.0 or not 1 <= args.wait_seconds <= 300:
        parser.error("Handoff 21 runner requires exactly 10 pairs, max load 6, and wait <=300s")
    args.evidence_dir = str(Path(args.evidence_dir).resolve())
    if not Path(args.evidence_dir).is_relative_to(Path("/private/tmp")):
        parser.error("Evidence directory must be under /private/tmp")
    for attr in ("baseline_root", "candidate_root", "baseline_derived_data", "candidate_derived_data", "lock"):
        value = Path(getattr(args, attr))
        if not value.is_absolute():
            parser.error(attr.replace("_", "-") + " must be absolute")
    if Path(args.baseline_derived_data).resolve() == Path(args.candidate_derived_data).resolve():
        parser.error("Each product requires its own prebuilt derivedDataPath")
    return args


def load_method(candidate_root, pairs):
    path = Path(candidate_root) / "docs/evidence/editor-highlight-schedule-paired.py"
    spec = importlib.util.spec_from_file_location("handoff22_paired_method", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.PAIRS = pairs
    return module


def sources(args):
    return {"baseline": args.baseline_root, "candidate": args.candidate_root}


def verify_source_heads(args):
    expected = {"baseline": BASELINE_SHA, "candidate": args.candidate_sha}
    for name, root in sources(args).items():
        if command(["git", "rev-parse", "HEAD"], root) != expected[name]:
            raise RuntimeError(name + " HEAD differs from its prebuilt commit")
        if command(["git", "status", "--porcelain=v1", "--untracked-files=all"], root):
            raise RuntimeError(name + " must be clean before measuring prebuilt products")
        if not (Path(root) / "Plainsong.xcodeproj").is_dir():
            raise RuntimeError(name + " generated Xcode project is missing; root must prepare it")


def prebuilt_provenance(args, name):
    derived = Path(getattr(args, name + "_derived_data"))
    products = derived / "Build/Products"
    manifests = sorted(products.glob("*.xctestrun"))
    if not manifests:
        raise RuntimeError(name + " has no prebuilt xctestrun under " + str(products))
    artifacts = []
    for bundle in sorted(products.glob("Debug/*.app")) + sorted(products.glob("Debug/*.xctest")):
        info = bundle / "Contents/Info.plist"
        if not info.is_file():
            continue
        with info.open("rb") as stream:
            executable_name = plistlib.load(stream).get("CFBundleExecutable")
        if executable_name:
            executable = bundle / "Contents/MacOS" / executable_name
            if executable.is_file():
                artifacts.append({"path": str(executable), "sha256": sha256(executable)})
    if not artifacts:
        raise RuntimeError(name + " has no Debug app/test executable; root must prebuild it")
    return {
        "derivedDataPath": str(derived),
        "xctestrun": [{"path": str(path), "sha256": sha256(path)} for path in manifests],
        "executables": artifacts,
    }


def measurement_inputs(root):
    root = Path(root)
    probe = root / "AppTests/EditorHighlightScheduleHostedTests.swift"
    timed = probe.read_text().split("    private func assertHostedLargeFixtureTyping", 1)[1].split("    /// Waits until", 1)[0].split("    private static func requireHostedOptIn", 1)[0].strip()
    return {
        "fixture_sha256": sha256(root / "Fixtures/large-1mb.md"),
        "manifest_sha256": sha256(root / "project.yml"),
        "probe_sha256": sha256(probe),
        "typing_probe_sha256": hashlib.sha256(timed.encode()).hexdigest(),
    }


def analyze(method, batches, pair_count):
    analysis = {}
    for mode in method.MODES:
        pairs, all_a, all_b = [], [], []
        for iteration in range(1, pair_count + 1):
            a = next((b for b in batches if b["product"] == "baseline" and b["iteration"] == iteration), None)
            b = next((b for b in batches if b["product"] == "candidate" and b["iteration"] == iteration), None)
            if not a or not b or not a["valid_measurement_batch"] or not b["valid_measurement_batch"]:
                continue
            sa, sb = a["samples"][mode], b["samples"][mode]
            pairs.append({"pair": iteration, "baseline": method.summary(sa), "candidate": method.summary(sb)})
            all_a.extend(sa)
            all_b.extend(sb)
        if not pairs:
            analysis[mode] = {"status": "still pending", "complete_pairs": 0}
            continue
        metrics = {
            metric: method.differences([p["candidate"][metric] - p["baseline"][metric] for p in pairs])
            for metric in ("median_ms", "p95_ms")
        }
        complete = len(pairs) == pair_count
        signal = complete and any(metric["regression_signal"] for metric in metrics.values())
        analysis[mode] = {
            "complete_pairs": len(pairs), "baseline": method.summary(all_a), "candidate": method.summary(all_b),
            "pairs": pairs, "metrics": metrics,
            "verdict": ("regression signal" if signal else "no regression signal detected under recorded load")
            if complete else "still pending; insufficient pairs",
            "limitation": "Differences smaller than the CI width cannot be excluded. Fractions over 16ms are observed under load; absolute idle acceptance remains open.",
        }
    return analysis


def batch(args, method):
    name, iteration = args.batch_product, args.batch_iteration
    output, root = Path(args.evidence_dir), sources(args)[name]
    start = method.snapshot()
    with (output / "admission.jsonl").open("a") as stream:
        stream.write(json.dumps({"product": name, "iteration": iteration, "snapshot": start}) + "\n")
    if start["load"][0] > args.max_load or start["build_processes"]:
        print(f"NOT_QUIET {name}-{iteration} load={start['load'][0]:.2f} builds={','.join(start['build_processes']) or 'none'}", flush=True)
        return 75
    verify_source_heads(args)
    stem = f"{name}-{iteration:02d}-test-without-building"
    log = output / (stem + ".log")
    metadata = {
        "product": name, "iteration": iteration, "action": "test-without-building",
        "product_sha": command(["git", "rev-parse", "HEAD"], root), "start": start,
        **measurement_inputs(root),
        "derivedDataPath": getattr(args, name + "_derived_data"),
    }
    cmd = [
        "xcodebuild", "-project", "Plainsong.xcodeproj", "-scheme", "Plainsong",
        "-configuration", "Debug", "-destination", "platform=macOS", "-parallel-testing-enabled", "NO",
        "-derivedDataPath", metadata["derivedDataPath"], "-resultBundlePath", str(output / (stem + ".xcresult")),
        "test-without-building", *["-only-testing:" + test for test in TESTS],
    ]
    env = dict(os.environ, TEST_RUNNER_PLAINSONG_RUN_HOSTED_TYPING_GATE="1")
    with log.open("w") as stream:
        stream.write(json.dumps(metadata) + "\n")
        stream.flush()
        result = subprocess.run(cmd, cwd=root, env=env, stdout=stream, stderr=subprocess.STDOUT)
    metadata.update(end=method.snapshot(), exit_code=result.returncode, raw_log=str(log), samples={})
    raw = log.read_text()
    for mode in method.MODES:
        matches = re.findall(r"Hosted " + re.escape(mode) + r" large-1mb\.md typing milliseconds: (\[[^\]\n]+\]); maximum:", raw)
        if matches:
            metadata["samples"][mode] = json.loads(matches[-1])
    failures = [line for line in raw.splitlines() if " error: " in line and ("failed" in line or "XCT" in line)]
    metadata["assertion_failure_lines"] = failures
    valid = all(len(metadata["samples"].get(mode, [])) == 30 for mode in method.MODES)
    valid = valid and (result.returncode == 0 or (result.returncode == 65 and failures and all("native input including debounce scheduling:" in line for line in failures)))
    metadata["valid_measurement_batch"] = bool(valid)
    (output / (stem + ".json")).write_text(json.dumps(metadata, indent=2) + "\n")
    print(f"BATCH {name}-{iteration:02d} exit={result.returncode} valid={bool(valid)} load={start['load'][0]:.2f}->{metadata['end']['load'][0]:.2f}", flush=True)
    return 0 if valid else 2


def main():
    args = parse_arguments()
    method = load_method(args.candidate_root, args.pairs)
    if args.batch_product:
        return batch(args, method)
    verify_source_heads(args)
    inputs = {name: measurement_inputs(root) for name, root in sources(args).items()}
    if inputs["baseline"] != inputs["candidate"]:
        raise RuntimeError("Baseline/candidate fixture, manifest, or typing probe differ")
    provenance = {name: prebuilt_provenance(args, name) for name in sources(args)}
    output = Path(args.evidence_dir)
    output.mkdir(parents=True, exist_ok=False)
    Path(args.lock).parent.mkdir(parents=True, exist_ok=True)
    source_fingerprints = {}
    for name, root in sources(args).items():
        fingerprint = content_fingerprint(root)
        fingerprint_path = output / (name + "-source-fingerprint.json")
        fingerprint_path.write_text(json.dumps(fingerprint, indent=2) + "\n")
        source_fingerprints[name] = {key: value for key, value in fingerprint.items() if key != "manifest"}
        source_fingerprints[name]["manifest_path"] = str(fingerprint_path)
    verify_source_heads(args)
    evidence = {
        "created_utc": datetime.now(timezone.utc).isoformat(), "status": "running",
        "method": "AB interleaved; prebuilt Debug products; 30 keystrokes per mode; no documented warm-up discarded; per-pair median/p95; 10000 bootstrap resamples; seed 20261004",
        "max_load": args.max_load, "requested_pairs": args.pairs, "quiet_wait_seconds": args.wait_seconds,
        "lock": args.lock, "baseline_sha": BASELINE_SHA, "candidate_sha": args.candidate_sha,
        "source_fingerprints": source_fingerprints, "prebuilt_provenance": provenance,
        "measurement_inputs": inputs,
        "method_source": str(Path(args.candidate_root) / "docs/evidence/editor-highlight-schedule-paired.py"),
        "method_source_sha256": sha256(Path(args.candidate_root) / "docs/evidence/editor-highlight-schedule-paired.py"),
        "runner_sha256": sha256(__file__), "absolute_idle_acceptance": "pending R9 / PR I or owner run",
        "run_attempts": [],
    }

    def save():
        evidence["batches"] = [json.loads(path.read_text()) for path in sorted(output.glob("*-test-without-building.json"))]
        admissions = output / "admission.jsonl"
        evidence["admission_checks"] = [json.loads(line) for line in admissions.read_text().splitlines()] if admissions.exists() else []
        evidence["analysis"] = analyze(method, evidence["batches"], args.pairs)
        (output / "evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")

    def run(name, iteration):
        deadline = time.monotonic() + args.wait_seconds
        while True:
            cmd = ["lockf", "-k", "-t", "0", args.lock, sys.executable, str(Path(__file__).resolve()),
                   *sys.argv[1:], "--batch-product", name, "--batch-iteration", str(iteration)]
            code = subprocess.run(cmd).returncode
            evidence["run_attempts"].append({
                "product": name, "iteration": iteration, "return_code": code,
                "recorded_utc": datetime.now(timezone.utc).isoformat(),
            })
            save()
            if code == 0:
                return
            if code not in (1, 75):
                evidence["status"] = "blocked by source/product/test failure; no verdict"
                save()
                raise SystemExit(code)
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                reason = "shared lock timeout" if code == 1 else "quiet-machine admission timeout"
                evidence["status"] = "still pending; " + reason
                save()
                print("PENDING " + reason + "; evidence=" + str(output / "evidence.json"), flush=True)
                raise SystemExit(75)
            time.sleep(min(30, remaining))

    print("EVIDENCE " + str(output), flush=True)
    save()
    for iteration in range(1, args.pairs + 1):
        run("baseline", iteration)
        run("candidate", iteration)
    evidence["status"] = "regression signal; stopped" if any(result.get("verdict") == "regression signal" for result in evidence["analysis"].values()) else "complete; observed under recorded load"
    save()
    for mode, result in evidence["analysis"].items():
        print(f"RESULT {mode}: {result['verdict']}; pairs={result['complete_pairs']}", flush=True)
    print("REPORT " + str(output / "evidence.json"), flush=True)
    return 3 if evidence["status"].startswith("regression signal") else 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError, subprocess.CalledProcessError) as error:
        print("ERROR " + str(error), file=sys.stderr, flush=True)
        raise SystemExit(2)
