#!/usr/bin/env python3
"""Run lane 06 guard mutations only in a disposable package snapshot.

The managed worktree is never mutated. A failed admission or infrastructure
run is retained and cannot count as a killed probe.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import shutil
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument("--source", required=True, type=Path)
parser.add_argument("--output", required=True, type=Path)
parser.add_argument("--device", required=True)
parser.add_argument("--expected-count", type=int, required=True)
parser.add_argument("--operation-timeout", type=int, default=600)
args = parser.parse_args()
source = args.source.resolve()
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
snapshot = output / "probe-source"
packages = ["MarkdownCore", "WorkspaceCore", "PreviewKit", "WorkspaceKitIOS"]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def fingerprint(root):
    values = {}
    for name in packages:
        package = root / "Packages" / name
        paths = [package / "Package.swift"]
        for directory in ["Sources", "Tests"]:
            paths.extend((package / directory).rglob("*.swift"))
        for path in paths:
            if path.is_file():
                values[str(path.relative_to(root))] = digest(path)
    return dict(sorted(values.items()))


expected = fingerprint(source)
manifest = output / "source-input-sha256.json"
if manifest.exists():
    if json.loads(manifest.read_text()) != expected:
        raise SystemExit("source changed; choose a new output directory")
else:
    manifest.write_text(json.dumps(expected, indent=2) + "\n")
if not snapshot.exists():
    for name in packages:
        shutil.copytree(
            source / "Packages" / name,
            snapshot / "Packages" / name,
            ignore=shutil.ignore_patterns(".build", ".swiftpm"),
        )
if fingerprint(snapshot) != expected:
    raise SystemExit("snapshot not restored; refusing to run")

records_path = output / "runs.json"
records = json.loads(records_path.read_text()) if records_path.exists() else []


def run(label, selector=None):
    previous = [item for item in records if item["label"] == label]
    if previous and previous[-1].get("accepted"):
        return previous[-1]
    attempt = len(previous) + 1
    key = f"{label}-{attempt}"
    result = output / f"{key}.xcresult"
    command = [
        "lockf", "-k", "-t", "180", "/private/tmp/plainsong-xcodebuild-test.lock",
        "xcodebuild", "test", "-scheme", "WorkspaceKitIOS", "-sdk", "iphonesimulator",
        "-destination", f"platform=iOS Simulator,id={args.device}",
        "-derivedDataPath", str(output / "DerivedData"),
        "-resultBundlePath", str(result), "-parallel-testing-enabled", "NO",
        "-collect-test-diagnostics", "never", "-test-timeouts-enabled", "YES",
        "-maximum-test-execution-time-allowance", "60",
        "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO",
    ]
    if selector:
        command.append(f"-only-testing:WorkspaceKitIOSTests/{selector}")
    record = {
        "label": label,
        "attempt": attempt,
        "command": command,
        "xcresult_path": str(result),
        "cwd": str(snapshot / "Packages/WorkspaceKitIOS"),
        "started_epoch": time.time(),
        "operation_timeout_seconds": args.operation_timeout,
        "timed_out": False,
    }
    with (output / f"{key}.log").open("w") as log:
        process = subprocess.Popen(
            command,
            cwd=record["cwd"],
            stdout=log,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        record["launcher_pid"] = process.pid
        record["process_group_id"] = process.pid
        try:
            process.wait(timeout=args.operation_timeout)
        except subprocess.TimeoutExpired:
            record["timed_out"] = True
            os.killpg(process.pid, signal.SIGINT)
            try:
                process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=30)
    record.update(exit_code=process.returncode, finished_epoch=time.time())
    summary = subprocess.run(
        ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result)],
        capture_output=True,
        text=True,
    )
    record["summary_exit_code"] = summary.returncode
    (output / f"{key}-summary.json").write_text(summary.stdout)
    (output / f"{key}-summary.stderr").write_text(summary.stderr)
    if summary.returncode == 0:
        record["summary"] = json.loads(summary.stdout)
        tests = subprocess.run(
            ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(result)],
            capture_output=True,
            text=True,
        )
        record["named_tests_exit_code"] = tests.returncode
        (output / f"{key}-tests.json").write_text(tests.stdout)
        (output / f"{key}-tests.stderr").write_text(tests.stderr)
    records.append(record)
    records_path.write_text(json.dumps(records, indent=2) + "\n")
    return record


service = "Packages/WorkspaceKitIOS/Sources/WorkspaceKitIOS/Access/IOSWorkspaceAccessService.swift"
coordination = "Packages/WorkspaceKitIOS/Sources/WorkspaceKitIOS/Workspace/IOSWorkspaceAccessService+Coordination.swift"
assets = "Packages/WorkspaceKitIOS/Sources/WorkspaceKitIOS/Workspace/IOSWorkspaceAccessService+Assets.swift"
probes = [
    (
        "empty-failure",
        coordination,
        "                // LANE06_GUARD_EMPTY_FAILURE\n                throw error\n",
        "                // LANE06_GUARD_EMPTY_FAILURE\n                data = Data()\n",
        "IOSWorkspaceSnapshotRaceTests/testReadFailureDoesNotReturnEmptyBytes",
    ),
    (
        "directory-grant",
        assets,
        "        // LANE06_GUARD_DIRECTORY_GRANT\n        guard grant.scope == .directory else {\n            throw IOSAssetStageFailure.failed(.requiresDirectoryGrant)\n        }\n",
        "        // LANE06_GUARD_DIRECTORY_GRANT\n        if false {\n            throw IOSAssetStageFailure.failed(.requiresDirectoryGrant)\n        }\n",
        "IOSWorkspaceAssetAndPreviewTests/testSingleFileGrantDoesNotStageIntoParent",
    ),
    (
        "single-file-scope",
        service,
        "            guard IOSWorkspacePathAuthority.sameFile(record.rootURL, location.fileURL) else {\n                throw IOSWorkspaceFailure.outsideGrant\n            }\n",
        "            let parent = record.rootURL.deletingLastPathComponent()\n            guard IOSWorkspacePathAuthority.directoryContains(\n                root: parent,\n                file: location.fileURL,\n                relativePath: location.relativePath\n            ) else {\n                throw IOSWorkspaceFailure.outsideGrant\n            }\n",
        "IOSWorkspaceBookmarkTests/testSingleFileGrantDoesNotReadASibling",
    ),
    (
        "denied-bookmark",
        service,
        "        if let failure = resolution.failure {\n            if failure == .offline {\n                throw IOSWorkspaceFailure.offline\n            }\n            markBookmark(bookmark, status: .needsReselection)\n            throw failure\n        }\n",
        "        if false, let failure = resolution.failure {\n            if failure == .offline {\n                throw IOSWorkspaceFailure.offline\n            }\n            markBookmark(bookmark, status: .needsReselection)\n            throw failure\n        }\n",
        "IOSWorkspaceBookmarkTests/testFreshStaleDeniedAndOfflineBookmarks",
    ),
    (
        "consumer-count",
        service,
        "            record.consumerCount -= 1\n",
        "            _ = record.consumerCount\n",
        "IOSWorkspaceLeaseRaceTests/testTwoConsumersEarlyReleaseDoesNotStopScope",
    ),
    (
        "generation",
        service,
        "        guard ticket.generation == record.generation, ticket.rootToken == record.rootToken else {\n            throw IOSWorkspaceFailure.grantChanged\n        }\n",
        "        if false, ticket.generation != record.generation || ticket.rootToken != record.rootToken {\n            throw IOSWorkspaceFailure.grantChanged\n        }\n",
        "IOSWorkspaceLeaseRaceTests/testLateReadAfterInvalidationDoesNotReturnBytes",
    ),
]

for label, relative, before, after, selector in probes:
    previous = [item for item in records if item["label"] == label]
    if previous and previous[-1].get("accepted"):
        continue
    path = snapshot / relative
    original = path.read_bytes()
    text = original.decode()
    if text.count(before) != 1:
        raise SystemExit(f"mutation anchor is ambiguous: {label}")
    path.write_text(text.replace(before, after, 1))
    mutation_hash = digest(path)
    try:
        record = run(label, selector)
    finally:
        path.write_bytes(original)
    record["mutated_path"] = relative
    record["mutated_sha256"] = mutation_hash
    record["original_sha256"] = hashlib.sha256(original).hexdigest()
    record["restored_sha256"] = digest(path)
    record["restored_all_inputs"] = fingerprint(snapshot) == expected
    summary = record.get("summary", {})
    record["accepted"] = (
        not record["timed_out"]
        and record["exit_code"] == 65
        and summary.get("totalTestCount") == 1
        and summary.get("failedTests") == 1
        and summary.get("skippedTests") == 0
        and selector.split("/")[-1] in json.dumps(summary.get("testFailures", []))
        and record.get("named_tests_exit_code") == 0
        and record["restored_all_inputs"]
    )
    records_path.write_text(json.dumps(records, indent=2) + "\n")
    print(json.dumps({key: record.get(key) for key in ["label", "exit_code", "accepted", "restored_all_inputs"]}), flush=True)
    if not record["accepted"]:
        raise SystemExit(f"probe {label} did not produce one real failing test; see retained log")

record = run("restored-module")
summary = record.get("summary", {})
record["restored_all_inputs"] = fingerprint(snapshot) == expected
record["accepted"] = (
    not record["timed_out"]
    and record["exit_code"] == 0
    and summary.get("totalTestCount") == args.expected_count
    and summary.get("passedTests") == args.expected_count
    and summary.get("failedTests") == 0
    and summary.get("skippedTests") == 0
    and record.get("named_tests_exit_code") == 0
    and record["restored_all_inputs"]
)
records_path.write_text(json.dumps(records, indent=2) + "\n")
print(json.dumps({key: record.get(key) for key in ["label", "exit_code", "accepted", "restored_all_inputs"]}), flush=True)
if not record["accepted"]:
    raise SystemExit(f"restored module failed or did not execute exactly {args.expected_count} tests")
