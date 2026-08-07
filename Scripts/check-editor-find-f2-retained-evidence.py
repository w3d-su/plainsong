#!/usr/bin/python3

"""Audit the compact, retained Phase 3 F2 performance evidence pack.

The default audit is intentionally limited to the retained compact pack. It
re-parses every timing and warning-phase claim, but treats omitted build
products and xcresult bundles as provenance-only. Passing --artifact-root
additionally rehashes those full artifacts and inspects fresh xcresult copies.
"""

from __future__ import annotations

import argparse
import base64
import contextlib
import hashlib
import io
import json
import os
import pwd
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path, PurePosixPath


SOURCE_COMMIT = "c871ddf5c66c17f03fd9456b53f79411f9b2e979"
SOURCE_ARCHIVE_SHA256 = "f0b84f1b43145b443364b28666710166debcd0c0342dad6e90092c2c70e55506"
SOURCE_TREE_SHA256 = "51b3c5309d67603ac8a4f298deed795d3c4afa597f0ac83cfcc3632e0abfda94"
RESOLVED_PACKAGE_INPUT_SHA256 = (
    "ed48178719a6c72d2880d3972e900d3bbe51f180d13e01dffd452de936f779c3"
)
XCODEGEN_SHA256 = "3b483413a801394b00adb2fabf3c06ff8f800c73c8698e1f9a9d8a95d73939ef"
EXPECTED_BUILD_IDENTITIES = {
    "Debug": {
        "buildInputSHA256": "2093bf7df313cc13ae24c964a6661ae05d15471547c553fc295003bbebeba3b6",
        "hostBundleSHA256": "0d064a65f1fb385a24c0d1cc9424e1643156d8cb8faabe673bafc6c0ca8f0d89",
        "xctestrunRelativePath": "Build/Products/Plainsong_macosx27.0-arm64.xctestrun",
        "xctestrunSHA256": "3f4dccaeb240b9fc90b42c60cbcbf77f73a13032586c4ce016380e4260a912e1",
    },
    "Release": {
        "buildInputSHA256": "3b8012362941b304eb7d7812a8b6e3c9196b49555060af8164db4dadbe4f1fb6",
        "hostBundleSHA256": "636f6b4b26a22964250675b15b0dbca6b57d1ebb3d54289312c95a82b0b9487c",
        "xctestrunRelativePath": "Build/Products/Plainsong_macosx27.0-arm64-x86_64.xctestrun",
        "xctestrunSHA256": "1eae5b26c52fa6f58146e487dce6d846216f653f541c3c2b41ed706a54ec0fc6",
    },
}
FIXTURE_SHA256 = "d174f48ea6175db568abe44e5b71e82ee92f1cf9c0ed081d8f8308cc1961d247"
FIXTURE_BYTES = 1_048_962
WARNING_CHECKER_SHA256 = (
    "385e83e5f0f30192ee9ff3f429fe342b5e7a52dabd5b784b3b998a0800956aac"
)
WARNING_MESSAGE = (
    "Modifying state during view update, this will cause undefined behavior."
)
EXPECTED_RUN_IDS = (
    "debug-1",
    "debug-2",
    "debug-3",
    "release-1",
    "release-2",
    "release-3",
)
PACK_INVENTORY_SHA256 = "d2f1497b19c37db3b49b5028292871fe6194752d94de05f55d5e7b6337767e22"
EXPECTED_RUN_IDENTITIES = {
    "debug-1": {
        "phaseId": "b8bd411a-f084-4bd6-96d7-f3c9643e0932",
        "rawLogSHA256": "7f5b2555b869eb4272f3b41e682d3b58fb4d1f9d736cf28f74d08a19f10c9c87",
        "warningCheckSHA256": "06304d424605ef0d438dc48327e84e7680b175555d208a255b847970e308473d",
        "xcresultSHA256": "2a36f1f0f1552e8405aea6a9c6e37cedb7aeed25c1468b2fcc31a17c59025d36",
        "inspectionXcresultSHA256": "2e0b3ba8fda4525f84f87e9f221dca3b5c9b9155ce93da1f25d72f3743f81b1c",
    },
    "debug-2": {
        "phaseId": "3b3ad8c9-2487-4ae7-ae91-a037344d058b",
        "rawLogSHA256": "f423e80f01fe3358e4f8c74937af32234e348a9118c3e773746ddcaa54fa295b",
        "warningCheckSHA256": "d37f6218eda964fce2d7f0c02681f0ae412c1649d123bcbd2de012d4569e3927",
        "xcresultSHA256": "a743d37e8af25036b53b1a02daa54785d15313d2115a1de821fa070b8a84ffab",
        "inspectionXcresultSHA256": "5482591b7c99424c3bb480a8f03d8b8a12768a92c7f85840578c6902a247d9a3",
    },
    "debug-3": {
        "phaseId": "bc493029-237a-4438-af59-c778f4f294f6",
        "rawLogSHA256": "b97bf3663dbc79316c3312b6238736e3bf7a33e8960985dee38b4da2547e5507",
        "warningCheckSHA256": "32675382be4b9453b62808c24941840bb04d90744028019839ba9d43efe39b0c",
        "xcresultSHA256": "4b64721255085afbfbc5cf2365c7f1824b7195ee9c766e837f600b8a45841bdb",
        "inspectionXcresultSHA256": "6bac0e9446f10eeec09896dae932a942e26a9a88f5f8d6ce6f68353e7e48b4f9",
    },
    "release-1": {
        "phaseId": "6c68a1f6-7cd6-4b19-9959-40ddab397737",
        "rawLogSHA256": "7b2320385c7f5293fe81f3b8a481c17a577d4a6739b44595867c23ce09aaa771",
        "warningCheckSHA256": "cba680af84812d89a3835abc9e482d45aa897c2eec853cd6cd205cf94c597c59",
        "xcresultSHA256": "8e4a78681a1ca1f0e6f214a137deeab5c2ae18ffbb01876f4fbd57b74cf2826f",
        "inspectionXcresultSHA256": "0a1a5dc3f4e5d587677089461f07ada1a957182ef74c1135d0fd3145cab8409b",
    },
    "release-2": {
        "phaseId": "c6abf3b0-a1e3-49cd-829a-d15fd49c9d99",
        "rawLogSHA256": "307ca9866fb40f9942b80db59617d6f7dd68e570a77207ba496228ed936918f3",
        "warningCheckSHA256": "6b38a9f72412b7bb049b466a72e39147dc8500a22cea1f8f8afb63ad963acfed",
        "xcresultSHA256": "d400fa26d00c67ecd8ffff56b7288a303f4e9cfee769015f4c0a8f9103d430b0",
        "inspectionXcresultSHA256": "466aa01922200f8677810398857fcfcdba769f0c6cbce89e1ada00a6e0e0294e",
    },
    "release-3": {
        "phaseId": "6b3b97ed-37c5-4fc5-b24f-34e6ddb464e9",
        "rawLogSHA256": "50be75593b20576ce8fad502328b87fb936c6142ee31baee14d58989fa5094f1",
        "warningCheckSHA256": "f5f164cf10e79ebe9a2ad328d7627a8c481af758de5118c9043347935e22acb8",
        "xcresultSHA256": "07c2b39e2d93a1b09dce353acac815328cee0bb4b44b3e328efc46ccdbc53e59",
        "inspectionXcresultSHA256": "f212519e07cf8e6ff3f480babe47f43d6184d9c69d8f58dff780f53b841dad28",
    },
}
EXPECTED_TESTS = (
    "testLargeFixtureFindQueryCompletionForZeroSparseAndDenseCases",
    "testProductionWorkspaceFindOpenEditAdmissionAndStateReceiptStayWithinMeasuredBudgets",
)
EXPECTED_BUDGETS = {
    "zeroQueryCompletion": Decimal("400"),
    "sparseQueryCompletion": Decimal("400"),
    "denseTruncatedQueryCompletion": Decimal("1100"),
    "nativeEditAdmission": Decimal("5"),
    "rootStateUpdateReceipt": Decimal("15"),
}
EXPECTED_FIXTURE = {
    "path": "Fixtures/large-1mb.md",
    "bytes": FIXTURE_BYTES,
    "sha256": FIXTURE_SHA256,
    "expectations": {
        "zero": {
            "query": "plainsong-f2-zero-hit",
            "retained": 0,
            "truncated": False,
            "first": None,
            "last": None,
        },
        "sparse": {
            "query": "generated sections: 1274",
            "retained": 1,
            "truncated": False,
            "first": {"location": 1_048_904, "length": 24, "line": 33_140},
            "last": {"location": 1_048_904, "length": 24, "line": 33_140},
        },
        "denseTruncated": {
            "query": "section",
            "retained": 10_000,
            "truncated": True,
            "overflowOrdinal": 10_001,
            "first": {"location": 399, "length": 7, "line": 15},
            "last": {"location": 914_752, "length": 7, "line": 28_901},
        },
    },
}
EXPECTED_BOUNDARIES = {
    "queryCompletionProxy": "pass",
    "nativeEditAdmissionProxy": "pass",
    "rootStateUpdateReceiptProxy": "pass",
    "warningPhase": "audited",
    "fullKeystrokeToScreen": "open",
    "f8HighlightApplyClear": "open",
    "f9": "open",
    "combinedTip": "open",
}
PROCESS_FILTER = (
    "xcodebuild|swift-frontend|swiftc|swift-driver|xctest|Plainsong|"
    "PlainsongUITests-Runner"
)
MONITOR_SAMPLE_INTERVAL_MILLISECONDS = 200
MONITOR_MAX_SAMPLE_GAP_MILLISECONDS = 1000
TRUSTED_COMMAND_TIMEOUT_SECONDS = 120
XCRESULTTOOL_TIMEOUT_SECONDS = 120
AUTHORITATIVE_RUN_TIMEOUT_SECONDS = 180
PARTIAL_AUDIT_EXIT_STATUS = 3
PROCESS_OWNERSHIP_RULE = "runner-ancestry-or-private-output-prefix-correlation"
RUNNER_ENVIRONMENT_POLICY = (
    "env-i-git-no-replace-home-lang-lc-all-path-tmpdir-user-logname"
)

RUN_FILE_NAMES = {
    "preflight": "preflight.txt",
    "preflightDigest": "preflight.txt.sha256",
    "competitionMonitor": "competition-monitor.log",
    "competitionMonitorDigest": "competition-monitor.log.sha256",
    "competitionMonitorSamples": "competition-monitor.samples.txt",
    "competitionMonitorSamplesDigest": "competition-monitor.samples.txt.sha256",
    "runOwnedProcesses": "run-owned-processes.log",
    "runOwnedProcessesDigest": "run-owned-processes.log.sha256",
    "competitionMonitorStatus": "competition-monitor.status.txt",
    "competitionMonitorStatusDigest": "competition-monitor.status.txt.sha256",
    "rawLog": "raw.log",
    "rawLogDigest": "raw.log.sha256",
    "warningCheck": "warning-check.txt",
    "warningCheckDigest": "warning-check.txt.sha256",
    "evidenceManifest": "evidence-manifest.txt",
    "outerLog": "outer.log",
    "outerLogDigest": "outer.log.sha256",
    "outerStatus": "outer.status.txt",
    "xcresultSummary": "xcresult-summary.json",
    "summaryProvenance": "summary-provenance.txt",
    "fullArtifactProvenance": "full-artifact-provenance.json",
    "postflight": "postflight.txt",
    "postflightDigest": "postflight.txt.sha256",
}
MONITOR_STATUS_KEYS = (
    "format",
    "monitor_pid",
    "runner_pid",
    "started_utc",
    "finished_utc",
    "first_sample_finished_utc",
    "last_sample_started_utc",
    "sample_interval_ms",
    "sample_count",
    "match_count",
    "run_owned_process_records",
    "runner_finished_before_sequence",
    "process_filter",
    "process_ownership_rule",
    "correlation_output_prefix",
    "allowed_host_executable",
    "allowed_run_prefix",
    "exit_status",
)
BUILD_KEYS = (
    "format",
    "source_commit",
    "configuration",
    "repository_root",
    "source_snapshot_path",
    "source_archive_path",
    "source_archive_sha256",
    "source_tree_sha256",
    "build_input_sha256",
    "package_input_path",
    "resolved_package_input_sha256",
    "xcodegen_path",
    "xcodegen_sha256",
    "destination",
    "budget_mode",
    "host_bundle_sha256",
    "xctestrun_relative_path",
    "xctestrun_sha256",
)
EVIDENCE_KEYS = (
    "format",
    "source_commit",
    "configuration",
    "build_manifest_path",
    "build_manifest_sha256",
    "raw_log_path",
    "raw_log_sha256",
    "raw_log_bytes",
    "xcresult_path",
    "xcresult_sha256",
    "xcresult_inspection_path",
    "xcresult_inspection_input_sha256",
    "xcresult_inspection_result_sha256",
    "warning_check_path",
    "warning_check_sha256",
    "warning_check_bytes",
    "status",
)
SOURCE_TOKEN_KEYS = (
    "commit",
    "configuration",
    "budget-mode",
    "build-manifest-readonly",
    "build-manifest-sha256",
    "exact-source-readonly",
    "build-input-sha256",
    "resolved-package-input-readonly",
    "resolved-package-input-sha256",
    "snapshot-readonly",
    "frozen-products",
    "host-bundle-sha256",
    "xctestrun-sha256",
    "raw-log-readonly",
    "raw-log-sha256",
    "xcresult-readonly",
    "xcresult-sha256",
    "xcresult-inspection-input-sha256",
)
WARNING_TOKEN_KEYS = (
    "id",
    "edits",
    "raw-known-pre",
    "raw-known-measured",
    "raw-known-post",
    "unknown-swiftui",
    "raw-log-sha256",
    "budget-mode",
    "budget-mode-markers",
    "xcresult-input-sha256",
    "xcresult-coalesced-known",
)
FINAL_TOKEN_KEYS = (
    "commit",
    "configuration",
    "build-manifest-readonly",
    "build-manifest-sha256",
    "exact-source-readonly",
    "resolved-package-input-readonly",
    "resolved-package-input-sha256",
    "snapshot-readonly",
    "raw-log-readonly",
    "raw-log-sha256",
    "xcresult-readonly",
    "xcresult-sha256",
    "xcresult-inspection-readonly",
    "xcresult-inspection-input-sha256",
    "xcresult-inspection-result-sha256",
    "warning-check-readonly",
    "warning-check-sha256",
    "evidence-manifest-readonly",
    "evidence-manifest-sha256",
)
FULL_ARTIFACT_NAMES = (
    "sourceArchive",
    "sourceSnapshot",
    "resolvedPackageInput",
    "buildManifest",
    "hostBundle",
    "xctestrun",
    "rawLog",
    "xcresult",
    "inspectionXcresult",
)
FULL_ARTIFACT_TYPES = {
    "sourceArchive": "file",
    "sourceSnapshot": "directory",
    "resolvedPackageInput": "directory",
    "buildManifest": "file",
    "hostBundle": "directory",
    "xctestrun": "file",
    "rawLog": "file",
    "xcresult": "directory",
    "inspectionXcresult": "directory",
}
GENERATED_SOURCE_SNAPSHOT_ENTRIES = {
    "App/Info.plist": "file",
    "App/Plainsong.entitlements": "file",
    "Packages/EditorKit/.swiftpm": "directory",
    "Packages/EditorKit/.swiftpm/xcode": "directory",
    "Packages/MarkdownCore/.swiftpm": "directory",
    "Packages/MarkdownCore/.swiftpm/xcode": "directory",
    "Packages/PreviewKit/.swiftpm": "directory",
    "Packages/PreviewKit/.swiftpm/xcode": "directory",
    "Packages/WorkspaceKit/.swiftpm": "directory",
    "Packages/WorkspaceKit/.swiftpm/xcode": "directory",
    "Plainsong.xcodeproj": "directory",
    "Plainsong.xcodeproj/project.pbxproj": "file",
    "Plainsong.xcodeproj/project.xcworkspace": "directory",
    "Plainsong.xcodeproj/project.xcworkspace/contents.xcworkspacedata": "file",
    "Plainsong.xcodeproj/project.xcworkspace/xcshareddata": "directory",
    "Plainsong.xcodeproj/project.xcworkspace/xcshareddata/swiftpm": "directory",
    "Plainsong.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/configuration": "directory",
    "Plainsong.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved": "file",
    "Plainsong.xcodeproj/xcshareddata": "directory",
    "Plainsong.xcodeproj/xcshareddata/xcschemes": "directory",
    "Plainsong.xcodeproj/xcshareddata/xcschemes/Plainsong.xcscheme": "file",
}

SHA256_RE = re.compile(r"[0-9a-f]{64}")
D3 = r"[0-9]+\.[0-9]{3}"
QUERY_RE = re.compile(
    rf"F2 PERF find query (?P<label>zero|sparse|dense-truncated) 1MB "
    rf"median (?P<median>{D3}) ms samples \[(?P<s1>{D3}), "
    rf"(?P<s2>{D3}), (?P<s3>{D3})\] \((?P<count>0|1|10000) "
    r"retained, truncated=(?P<truncated>true|false)\)$"
)
HOST_RE = re.compile(
    rf"F2 PERF production WorkspaceWindow find-open edit 1MB admission median "
    rf"(?P<admission_median>{D3}) ms samples \[(?P<a1>{D3}), "
    rf"(?P<a2>{D3}), (?P<a3>{D3}), (?P<a4>{D3}), (?P<a5>{D3})\]; "
    rf"state-update receipt median (?P<receipt_median>{D3}) ms max "
    rf"(?P<receipt_max>{D3}) ms samples \[(?P<r1>{D3}), (?P<r2>{D3}), "
    rf"(?P<r3>{D3}), (?P<r4>{D3}), (?P<r5>{D3})\]$"
)
MARKER_RE = re.compile(
    r"F2_WARNING_PHASE_(BEGIN|END) "
    r"id=([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}) "
    r"edits=([0-9]+)\s*$"
)
SWIFTUI_RE = re.compile(r"\[SwiftUI\] (.+?)\s*$")
BUDGET_MODE_RE = re.compile(r"F2 PERF budget mode (local-hard|ci-informational)\s*$")


class AuditError(Exception):
    """A falsified or incomplete retained-evidence claim."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AuditError(message)


def require_keys(value: object, keys: tuple[str, ...], label: str) -> dict:
    require(isinstance(value, dict), f"{label} must be an object")
    actual = set(value)
    expected = set(keys)
    require(
        actual == expected,
        f"{label} keys differ: missing={sorted(expected - actual)!r} "
        f"extra={sorted(actual - expected)!r}",
    )
    return value


def reject_json_constant(value: str) -> None:
    raise AuditError(f"non-finite JSON number is forbidden: {value}")


def unique_json_object(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise AuditError(f"duplicate JSON key: {key!r}")
        result[key] = value
    return result


def loads_json(data: bytes, label: str) -> object:
    try:
        text = data.decode("utf-8", errors="strict")
        return json.loads(
            text,
            object_pairs_hook=unique_json_object,
            parse_constant=reject_json_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise AuditError(f"{label} is not strict UTF-8 JSON: {error}") from error


def load_json(path: Path, label: str) -> object:
    try:
        return loads_json(path.read_bytes(), label)
    except OSError as error:
        raise AuditError(f"could not read {label} at {path}: {error}") from error


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as handle:
            while chunk := handle.read(1024 * 1024):
                digest.update(chunk)
    except OSError as error:
        raise AuditError(f"could not hash {path}: {error}") from error
    return digest.hexdigest()


def require_sha256(value: str, label: str) -> None:
    require(
        isinstance(value, str) and SHA256_RE.fullmatch(value) is not None,
        f"{label} is not a lowercase SHA-256: {value!r}",
    )


def safe_relative_path(value: object, label: str) -> str:
    require(isinstance(value, str) and value != "", f"{label} must be a path string")
    require("\\" not in value and "\x00" not in value, f"{label} is not POSIX-safe")
    path = PurePosixPath(value)
    require(not path.is_absolute(), f"{label} must be relative: {value}")
    require(
        all(part not in ("", ".", "..") for part in path.parts),
        f"{label} escapes its root: {value}",
    )
    require(path.as_posix() == value, f"{label} is not canonical: {value}")
    return value


def regular_pack_files(root: Path) -> set[str]:
    files: set[str] = set()

    def visit(directory: Path, prefix: PurePosixPath) -> None:
        try:
            entries = sorted(os.scandir(directory), key=lambda item: os.fsencode(item.name))
        except OSError as error:
            raise AuditError(f"could not inventory {directory}: {error}") from error
        for entry in entries:
            relative = (prefix / entry.name).as_posix()
            try:
                metadata = entry.stat(follow_symlinks=False)
            except OSError as error:
                raise AuditError(f"could not inspect {entry.path}: {error}") from error
            require(not stat.S_ISLNK(metadata.st_mode), f"pack symlink is forbidden: {relative}")
            if stat.S_ISDIR(metadata.st_mode):
                visit(Path(entry.path), prefix / entry.name)
            else:
                require(stat.S_ISREG(metadata.st_mode), f"non-file pack entry: {relative}")
                files.add(relative)

    visit(root, PurePosixPath())
    require("SHA256SUMS" in files, "pack is missing SHA256SUMS")
    return files


def validate_inventory(root: Path) -> dict[str, str]:
    inventory_path = root / "SHA256SUMS"
    try:
        data = inventory_path.read_bytes()
        text = data.decode("ascii", errors="strict")
    except (OSError, UnicodeDecodeError) as error:
        raise AuditError(f"could not read ASCII SHA256SUMS: {error}") from error
    require(
        sha256_bytes(data) == PACK_INVENTORY_SHA256,
        "SHA256SUMS is not the frozen final-six compact inventory",
    )
    require(text.endswith("\n"), "SHA256SUMS must end with LF")
    records: dict[str, str] = {}
    pattern = re.compile(r"([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9._/-]*)")
    for line_number, line in enumerate(text.splitlines(), start=1):
        match = pattern.fullmatch(line)
        require(match is not None, f"invalid SHA256SUMS line {line_number}: {line!r}")
        digest, relative = match.groups()
        safe_relative_path(relative, f"SHA256SUMS line {line_number}")
        require(relative != "SHA256SUMS", "SHA256SUMS cannot recursively inventory itself")
        require(relative not in records, f"duplicate SHA256SUMS path: {relative}")
        require(
            relative.casefold() not in {path.casefold() for path in records},
            f"case-colliding SHA256SUMS path: {relative}",
        )
        records[relative] = digest
    require(list(records) == sorted(records), "SHA256SUMS paths must be bytewise sorted")
    actual = regular_pack_files(root) - {"SHA256SUMS"}
    require(
        set(records) == actual,
        f"SHA256SUMS is not exact: missing={sorted(actual - set(records))!r} "
        f"stale={sorted(set(records) - actual)!r}",
    )
    for relative, expected in records.items():
        actual_digest = sha256_file(root / PurePosixPath(relative))
        require(actual_digest == expected, f"SHA256SUMS mismatch for {relative}")
    return records


def pack_file(root: Path, inventory: dict[str, str], relative: object, label: str) -> Path:
    value = safe_relative_path(relative, label)
    require(value in inventory, f"{label} is absent from SHA256SUMS: {value}")
    path = root.joinpath(*PurePosixPath(value).parts)
    require(path.is_file() and not path.is_symlink(), f"{label} is not a regular file: {value}")
    return path


def parse_key_values(path: Path, keys: tuple[str, ...], label: str) -> dict[str, str]:
    try:
        data = path.read_bytes()
        text = data.decode("utf-8", errors="strict")
    except (OSError, UnicodeDecodeError) as error:
        raise AuditError(f"could not read {label}: {error}") from error
    require(text.endswith("\n"), f"{label} must end with LF")
    result: dict[str, str] = {}
    order: list[str] = []
    for line_number, line in enumerate(text.splitlines(), start=1):
        require("=" in line, f"{label} line {line_number} has no equals sign")
        key, value = line.split("=", 1)
        require(re.fullmatch(r"[a-z0-9_]+", key) is not None, f"invalid {label} key: {key!r}")
        require(key not in result, f"duplicate {label} key: {key}")
        require(value != "", f"empty {label} value: {key}")
        result[key] = value
        order.append(key)
    require(tuple(order) == keys, f"{label} key order differs: {order!r}")
    return result


def parse_digest(path: Path, label: str) -> tuple[str, int]:
    record = parse_key_values(path, ("sha256", "bytes"), label)
    require_sha256(record["sha256"], f"{label} sha256")
    require(re.fullmatch(r"[0-9]+", record["bytes"]) is not None, f"invalid {label} byte count")
    return record["sha256"], int(record["bytes"])


def parse_rfc3339_utc(value: str, label: str, require_fraction: bool = False) -> datetime:
    fraction = r"\.[0-9]{6}" if require_fraction else r"(?:\.[0-9]{1,6})?"
    require(
        re.fullmatch(
            rf"[0-9]{{4}}-[0-9]{{2}}-[0-9]{{2}}T"
            rf"[0-9]{{2}}:[0-9]{{2}}:[0-9]{{2}}{fraction}Z",
            value,
        )
        is not None,
        f"{label} is not precise RFC3339 UTC" if require_fraction else f"{label} is not RFC3339 UTC",
    )
    try:
        timestamp = datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError as error:
        raise AuditError(f"{label} is invalid: {error}") from error
    require(timestamp.tzinfo == timezone.utc, f"{label} is not UTC")
    return timestamp


def parse_decimal_integer(value: str, label: str, positive: bool = False) -> int:
    require(re.fullmatch(r"[0-9]+", value) is not None, f"{label} is not a decimal integer")
    parsed = int(value)
    require(parsed > 0 if positive else parsed >= 0, f"{label} has the wrong sign")
    return parsed


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


def validate_manifest(manifest: object) -> dict:
    value = require_keys(
        manifest,
        (
            "format",
            "gate",
            "sourceCommit",
            "environment",
            "fixture",
            "warningChecker",
            "budgetsMilliseconds",
            "builds",
            "runs",
            "boundaries",
        ),
        "manifest.json",
    )
    require(value["format"] == 1, "manifest format must be 1")
    require(value["gate"] == "editor-find-f2-retained-evidence", "manifest gate differs")
    require(value["sourceCommit"] == SOURCE_COMMIT, "manifest source commit differs")
    environment = require_keys(
        value["environment"],
        (
            "recordedAt",
            "timeZone",
            "macOSVersion",
            "macOSBuild",
            "xcodeVersion",
            "xcodeBuild",
            "selectedDeveloperDir",
            "macOSSDKPath",
            "macOSSDKVersion",
            "macOSSDKBuild",
            "xcodegenVersion",
            "xcodegenSHA256",
            "xcresulttoolPath",
            "xcresulttoolSHA256",
            "architecture",
            "machineModel",
            "memoryBytes",
            "physicalCPUCount",
            "logicalCPUCount",
        ),
        "manifest environment",
    )
    for key in (
        "recordedAt",
        "timeZone",
        "macOSVersion",
        "macOSBuild",
        "xcodeVersion",
        "xcodeBuild",
        "selectedDeveloperDir",
        "macOSSDKPath",
        "macOSSDKVersion",
        "macOSSDKBuild",
        "xcodegenVersion",
        "xcresulttoolPath",
        "machineModel",
    ):
        require(isinstance(environment[key], str) and environment[key] != "", f"environment {key} is empty")
    require(environment["architecture"] in ("arm64", "x86_64"), "unsupported recorded architecture")
    require(PurePosixPath(environment["selectedDeveloperDir"]).is_absolute(), "selectedDeveloperDir is not absolute")
    require(PurePosixPath(environment["macOSSDKPath"]).is_absolute(), "macOSSDKPath is not absolute")
    require(PurePosixPath(environment["xcresulttoolPath"]).is_absolute(), "xcresulttoolPath is not absolute")
    require(
        environment["macOSSDKPath"].startswith(environment["selectedDeveloperDir"] + "/"),
        "macOSSDKPath is outside selectedDeveloperDir",
    )
    require(
        environment["xcresulttoolPath"].startswith(environment["selectedDeveloperDir"] + "/"),
        "xcresulttoolPath is outside selectedDeveloperDir",
    )
    require_sha256(environment["xcodegenSHA256"], "environment xcodegenSHA256")
    require_sha256(environment["xcresulttoolSHA256"], "environment xcresulttoolSHA256")
    require(
        isinstance(environment["memoryBytes"], int)
        and not isinstance(environment["memoryBytes"], bool)
        and environment["memoryBytes"] > 0,
        "environment memoryBytes must be positive",
    )
    for key in ("physicalCPUCount", "logicalCPUCount"):
        require(
            isinstance(environment[key], int)
            and not isinstance(environment[key], bool)
            and environment[key] > 0,
            f"environment {key} must be a positive integer",
        )
    require(
        environment["logicalCPUCount"] >= environment["physicalCPUCount"],
        "logicalCPUCount is smaller than physicalCPUCount",
    )
    require(value["fixture"] == EXPECTED_FIXTURE, "fixture identity/endpoints differ from c871")
    checker = require_keys(value["warningChecker"], ("path", "sha256"), "warningChecker")
    require(checker["path"] == "reference/check-editor-find-f2-warning-phase.py", "warning checker path differs")
    require(checker["sha256"] == WARNING_CHECKER_SHA256, "warning checker is not the c871 checker")
    budgets = require_keys(value["budgetsMilliseconds"], tuple(EXPECTED_BUDGETS), "budgetsMilliseconds")
    for key, expected in EXPECTED_BUDGETS.items():
        require(Decimal(str(budgets[key])) == expected, f"budget {key} differs from c871")
    require(value["boundaries"] == EXPECTED_BOUNDARIES, "gate boundaries overclaim the retained evidence")
    return value


def validate_build_manifest(fields: dict[str, str], configuration: str, environment: dict) -> None:
    require(fields["format"] == "5", f"{configuration} build manifest format is not 5")
    require(fields["source_commit"] == SOURCE_COMMIT, f"{configuration} build source differs")
    require(fields["configuration"] == configuration, f"{configuration} build configuration differs")
    require(fields["budget_mode"] == "local-hard", f"{configuration} build is not local-hard")
    for key in (
        "source_archive_sha256",
        "source_tree_sha256",
        "build_input_sha256",
        "resolved_package_input_sha256",
        "xcodegen_sha256",
        "host_bundle_sha256",
        "xctestrun_sha256",
    ):
        require_sha256(fields[key], f"{configuration} build {key}")
    for key in (
        "repository_root",
        "source_snapshot_path",
        "source_archive_path",
        "package_input_path",
        "xcodegen_path",
    ):
        require(PurePosixPath(fields[key]).is_absolute(), f"{configuration} build {key} is not absolute")
    snapshot = fields["source_snapshot_path"]
    require(snapshot.endswith(".source"), f"{configuration} source snapshot suffix differs")
    derived = snapshot[: -len(".source")]
    require(fields["source_archive_path"] == derived + ".source.tar", f"{configuration} source archive path differs")
    require(fields["package_input_path"] == derived + "/SourcePackages", f"{configuration} package path differs")
    require(
        fields["destination"] == f"platform=macOS,arch={environment['architecture']}",
        f"{configuration} destination differs from recorded environment",
    )
    xctestrun = safe_relative_path(fields["xctestrun_relative_path"], f"{configuration} xctestrun path")
    require(xctestrun.startswith("Build/Products/") and xctestrun.endswith(".xctestrun"), "invalid xctestrun path")
    expected_identity = EXPECTED_BUILD_IDENTITIES[configuration]
    expected = {
        "source_archive_sha256": SOURCE_ARCHIVE_SHA256,
        "source_tree_sha256": SOURCE_TREE_SHA256,
        "build_input_sha256": expected_identity["buildInputSHA256"],
        "resolved_package_input_sha256": RESOLVED_PACKAGE_INPUT_SHA256,
        "xcodegen_sha256": XCODEGEN_SHA256,
        "host_bundle_sha256": expected_identity["hostBundleSHA256"],
        "xctestrun_relative_path": expected_identity["xctestrunRelativePath"],
        "xctestrun_sha256": expected_identity["xctestrunSHA256"],
    }
    for key, value in expected.items():
        require(
            fields[key] == value,
            f"{configuration} build identity differs for {key}",
        )


def validate_run_paths(evidence: dict[str, str], source: dict[str, str]) -> str:
    raw = evidence["raw_log_path"]
    require(PurePosixPath(raw).is_absolute() and raw.endswith(".log"), "raw log original path is invalid")
    prefix = raw[: -len(".log")]
    require(evidence["xcresult_path"] == prefix + ".xcresult", "xcresult/raw prefix differs")
    require(
        evidence["xcresult_inspection_path"] == prefix + ".inspection.xcresult",
        "inspection/raw prefix differs",
    )
    require(evidence["warning_check_path"] == prefix + ".warning-check.txt", "warning/raw prefix differs")
    require(source["frozen-products"] == prefix + ".products", "product snapshot/raw prefix differs")
    return prefix


def validate_full_provenance(
    provenance: object,
    run_id: str,
    configuration: str,
    build: dict[str, str],
    build_manifest_sha256: str,
    evidence: dict[str, str],
    source: dict[str, str],
) -> dict:
    value = require_keys(
        provenance,
        (
            "format",
            "sourceCommit",
            "configuration",
            "runId",
            "retainedInPack",
            "retainedAtArtifactRoot",
            "verificationScope",
            "artifacts",
        ),
        f"{run_id} full-artifact provenance",
    )
    require(value["format"] == 1, f"{run_id}: provenance format differs")
    require(value["sourceCommit"] == SOURCE_COMMIT, f"{run_id}: provenance source differs")
    require(value["configuration"] == configuration, f"{run_id}: provenance configuration differs")
    require(value["runId"] == run_id, f"{run_id}: provenance run id differs")
    require(
        value["retainedInPack"] is False,
        f"{run_id}: compact pack must not claim full artifacts are stored in Git",
    )
    require(
        value["retainedAtArtifactRoot"] is True,
        f"{run_id}: provenance must record owner-local full-artifact retention",
    )
    require(
        value["verificationScope"] == "owner-local-full-artifact",
        f"{run_id}: full-artifact retention scope differs",
    )
    artifacts = require_keys(value["artifacts"], FULL_ARTIFACT_NAMES, f"{run_id} provenance artifacts")
    expected = {
        "sourceArchive": (build["source_archive_path"], "file-sha256", build["source_archive_sha256"]),
        "sourceSnapshot": (build["source_snapshot_path"], "artifact-sha256", build["build_input_sha256"]),
        "resolvedPackageInput": (
            build["package_input_path"],
            "resolved-package-input-sha256",
            build["resolved_package_input_sha256"],
        ),
        "buildManifest": (evidence["build_manifest_path"], "file-sha256", build_manifest_sha256),
        "hostBundle": (
            source["frozen-products"] + f"/Build/Products/{configuration}/Plainsong.app",
            "artifact-sha256",
            build["host_bundle_sha256"],
        ),
        "xctestrun": (
            source["frozen-products"] + "/" + build["xctestrun_relative_path"],
            "artifact-sha256",
            build["xctestrun_sha256"],
        ),
        "rawLog": (evidence["raw_log_path"], "file-sha256", evidence["raw_log_sha256"]),
        "xcresult": (evidence["xcresult_path"], "artifact-sha256", evidence["xcresult_sha256"]),
        "inspectionXcresult": (
            evidence["xcresult_inspection_path"],
            "artifact-sha256",
            evidence["xcresult_inspection_result_sha256"],
        ),
    }
    for name, (original, mode, digest) in expected.items():
        artifact = require_keys(
            artifacts[name],
            ("originalPath", "artifactRootPath", "hashMode", "sha256"),
            f"{run_id} provenance {name}",
        )
        require(artifact["originalPath"] == original, f"{run_id}: {name} original path differs")
        safe_relative_path(artifact["artifactRootPath"], f"{run_id} {name} artifactRootPath")
        require(artifact["hashMode"] == mode, f"{run_id}: {name} hash mode differs")
        require(artifact["sha256"] == digest, f"{run_id}: {name} digest differs")
    return value


def update_field(digest: object, value: bytes) -> None:
    digest.update(len(value).to_bytes(8, byteorder="big"))
    digest.update(value)


def update_entry_identity(digest: object, path: Path, relative: str) -> os.stat_result:
    metadata = path.lstat()
    executable = stat.S_IMODE(metadata.st_mode) & 0o111
    update_field(digest, relative.encode("utf-8", errors="surrogateescape"))
    update_field(digest, f"{executable:o}".encode("ascii"))
    return metadata


def hash_artifact_entry(
    digest: object,
    path: Path,
    relative: str,
    exclude_git: bool = False,
) -> None:
    metadata = update_entry_identity(digest, path, relative)
    if stat.S_ISLNK(metadata.st_mode):
        update_field(digest, b"symlink")
        update_field(digest, os.readlink(path).encode("utf-8", errors="surrogateescape"))
    elif stat.S_ISREG(metadata.st_mode):
        update_field(digest, b"file")
        update_field(digest, metadata.st_size.to_bytes(8, byteorder="big"))
        with path.open("rb") as handle:
            while chunk := handle.read(1024 * 1024):
                digest.update(chunk)
    elif stat.S_ISDIR(metadata.st_mode):
        update_field(digest, b"directory")
        for child in sorted(path.iterdir(), key=lambda item: os.fsencode(item.name)):
            if exclude_git and child.name == ".git":
                continue
            hash_artifact_entry(digest, child, f"{relative}/{child.name}", exclude_git)
    else:
        raise AuditError(f"unsupported artifact entry type: {path}")


def artifact_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        hash_artifact_entry(digest, path, "artifact")
    except OSError as error:
        raise AuditError(f"could not hash artifact {path}: {error}") from error
    return digest.hexdigest()


def require_artifact_entry_type(path: Path, expected_type: str, label: str) -> None:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise AuditError(f"could not inspect {label} at {path}: {error}") from error
    matches = (
        expected_type == "directory" and stat.S_ISDIR(metadata.st_mode)
    ) or (
        expected_type == "file" and stat.S_ISREG(metadata.st_mode)
    )
    require(matches, f"{label} is not a {expected_type}: {path}")


def path_identity(path: Path, label: str) -> tuple[int, int, int, int]:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise AuditError(f"could not identify {label} at {path}: {error}") from error
    require(not stat.S_ISLNK(metadata.st_mode), f"{label} must not be a symlink: {path}")
    return metadata.st_dev, metadata.st_ino, metadata.st_mode, metadata.st_uid


def require_owner_controlled_directory(path: Path, label: str) -> None:
    require_artifact_entry_type(path, "directory", label)
    metadata = path.lstat()
    require(metadata.st_uid == os.getuid(), f"{label} is not owned by the current user")
    require(
        stat.S_IMODE(metadata.st_mode) & 0o022 == 0,
        f"{label} is group/world writable",
    )


def require_read_only_tree(root: Path, label: str) -> None:
    try:
        root_metadata = root.lstat()
    except OSError as error:
        raise AuditError(f"could not inspect {label}: {error}") from error
    require(
        stat.S_ISDIR(root_metadata.st_mode),
        f"{label} root is not a directory",
    )
    require(
        root_metadata.st_uid == os.getuid(),
        f"{label} root is not owned by the current user",
    )
    require(
        stat.S_IMODE(root_metadata.st_mode) & 0o222 == 0,
        f"{label} root is writable",
    )

    def walk_error(error: OSError) -> None:
        raise AuditError(f"could not enumerate {label}: {error}")

    for directory, directory_names, file_names in os.walk(
        root,
        followlinks=False,
        onerror=walk_error,
    ):
        for name in directory_names + file_names:
            path = Path(directory) / name
            try:
                metadata = path.lstat()
            except OSError as error:
                raise AuditError(f"could not inspect {label} entry {path}: {error}") from error
            require(
                not stat.S_ISLNK(metadata.st_mode),
                f"{label} contains a symlink: {path}",
            )
            require(
                stat.S_ISDIR(metadata.st_mode) or stat.S_ISREG(metadata.st_mode),
                f"{label} contains an unsupported entry type: {path}",
            )
            require(
                metadata.st_uid == os.getuid(),
                f"{label} contains an entry not owned by the current user: {path}",
            )
            require(
                stat.S_IMODE(metadata.st_mode) & 0o222 == 0,
                f"{label} contains a writable entry: {path}",
            )
    try:
        acl_check = subprocess.run(
            ["/usr/bin/find", str(root), "-acl", "-print"],
            capture_output=True,
            check=False,
            timeout=60,
            env={"LC_ALL": "C", "PATH": "/usr/bin:/bin"},
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise AuditError(f"could not inspect ACLs for {label}: {error}") from error
    require(
        acl_check.returncode == 0,
        f"could not inspect ACLs for {label}: {acl_check.stderr[:512]!r}",
    )
    require(
        acl_check.stdout == b"",
        f"{label} contains an ACL-bearing entry",
    )


def tree_entries(root: Path, label: str) -> dict[str, tuple[str, int, str]]:
    require_artifact_entry_type(root, "directory", label)
    entries: dict[str, tuple[str, int, str]] = {}

    def visit(directory: Path, prefix: PurePosixPath) -> None:
        try:
            children = sorted(os.scandir(directory), key=lambda item: os.fsencode(item.name))
        except OSError as error:
            raise AuditError(f"could not enumerate {label} at {directory}: {error}") from error
        for child in children:
            relative = (prefix / child.name).as_posix()
            try:
                metadata = child.stat(follow_symlinks=False)
            except OSError as error:
                raise AuditError(f"could not inspect {label} entry {relative}: {error}") from error
            executable = stat.S_IMODE(metadata.st_mode) & 0o111
            path = Path(child.path)
            if stat.S_ISDIR(metadata.st_mode):
                entries[relative] = ("directory", executable, "")
                visit(path, prefix / child.name)
            elif stat.S_ISREG(metadata.st_mode):
                entries[relative] = ("file", executable, sha256_file(path))
            elif stat.S_ISLNK(metadata.st_mode):
                entries[relative] = (
                    "symlink",
                    executable,
                    os.readlink(path),
                )
            else:
                raise AuditError(f"unsupported {label} entry type: {relative}")

    visit(root, PurePosixPath())
    return entries


def reject_tree_symlinks(root: Path, label: str) -> None:
    for relative, (kind, _, _) in tree_entries(root, label).items():
        require(kind != "symlink", f"{label} contains forbidden symlink: {relative}")


def validate_generated_source_snapshot(canonical_root: Path, snapshot_root: Path) -> None:
    canonical = tree_entries(canonical_root, "canonical c871 source tree")
    snapshot = tree_entries(snapshot_root, "retained generated source snapshot")
    missing = sorted(set(canonical) - set(snapshot))
    require(not missing, f"generated source snapshot is missing tracked entries: {missing!r}")
    for relative, expected in canonical.items():
        require(
            snapshot[relative] == expected,
            f"generated source snapshot changed tracked bytes/type/mode: {relative}",
        )
    additions = set(snapshot) - set(canonical)
    require(
        additions == set(GENERATED_SOURCE_SNAPSHOT_ENTRIES),
        "generated source snapshot additions differ: "
        f"missing={sorted(set(GENERATED_SOURCE_SNAPSHOT_ENTRIES) - additions)!r} "
        f"unexpected={sorted(additions - set(GENERATED_SOURCE_SNAPSHOT_ENTRIES))!r}",
    )
    for relative, expected_type in GENERATED_SOURCE_SNAPSHOT_ENTRIES.items():
        actual_type, executable, _ = snapshot[relative]
        require(actual_type == expected_type, f"generated source entry type differs: {relative}")
        if expected_type == "file":
            require(executable == 0, f"generated source file is unexpectedly executable: {relative}")


def resolved_package_sha256(path: Path) -> str:
    require_artifact_entry_type(path, "directory", "resolved package input")
    allowed = {"artifacts", "checkouts", "repositories", "workspace-state.json"}
    names = {child.name for child in path.iterdir()}
    require(not names - allowed, f"unexpected resolved package entries: {sorted(names - allowed)!r}")
    checkouts = path / "checkouts"
    artifacts = path / "artifacts"
    state = path / "workspace-state.json"
    require_artifact_entry_type(checkouts, "directory", "resolved package checkouts")
    require_artifact_entry_type(artifacts, "directory", "resolved package artifacts")
    require_artifact_entry_type(state, "file", "resolved package workspace state")
    repositories = path / "repositories"
    if repositories.exists() or repositories.is_symlink():
        require_artifact_entry_type(
            repositories,
            "directory",
            "resolved package repositories",
        )
    digest = hashlib.sha256()
    metadata = update_entry_identity(digest, path, "artifact")
    require(stat.S_ISDIR(metadata.st_mode), "resolved package root is not a directory")
    update_field(digest, b"directory")
    entries = ((artifacts, False), (checkouts, True), (state, False))
    for child, exclude_git in sorted(entries, key=lambda item: os.fsencode(item[0].name)):
        hash_artifact_entry(digest, child, f"artifact/{child.name}", exclude_git)
    return digest.hexdigest()


def sanitized_subprocess_environment() -> dict[str, str]:
    account = pwd.getpwuid(os.getuid())
    require(
        account.pw_dir.startswith("/")
        and "\n" not in account.pw_dir
        and re.fullmatch(r"[A-Za-z0-9._-]+", account.pw_name) is not None,
        "local account identity is not safe for the audit subprocess environment",
    )
    return {
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_NO_REPLACE_OBJECTS": "1",
        "HOME": account.pw_dir,
        "LANG": "C",
        "LC_ALL": "C",
        "LOGNAME": account.pw_name,
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "TMPDIR": "/private/tmp",
        "USER": account.pw_name,
    }


def run_trusted_command(command: list[str], label: str) -> bytes:
    try:
        completed = subprocess.run(
            command,
            check=False,
            capture_output=True,
            env=sanitized_subprocess_environment(),
            timeout=TRUSTED_COMMAND_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired as error:
        raise AuditError(
            f"{label} timed out after {TRUSTED_COMMAND_TIMEOUT_SECONDS} seconds"
        ) from error
    require(
        completed.returncode == 0,
        f"{label} failed with status {completed.returncode}: "
        f"{completed.stderr.decode('utf-8', errors='replace').strip()}",
    )
    return completed.stdout


def verify_source_archive_commit(
    archive_path: Path,
    source_snapshot_path: Path,
    expected_archive_sha256: str,
    expected_source_tree_sha256: str,
) -> None:
    require(
        expected_archive_sha256 == SOURCE_ARCHIVE_SHA256,
        "recorded source archive is not the frozen c871 archive",
    )
    require(
        expected_source_tree_sha256 == SOURCE_TREE_SHA256,
        "recorded source tree is not the frozen c871 tree",
    )
    require(
        sha256_file(archive_path) == SOURCE_ARCHIVE_SHA256,
        "retained source archive differs from the frozen c871 archive",
    )
    with tempfile.TemporaryDirectory(
        prefix="plainsong-f2-source-audit.",
        dir="/private/tmp",
    ) as temporary:
        temporary_root = Path(temporary)
        extracted = temporary_root / "source"
        extracted.mkdir()
        run_trusted_command(
            ["/usr/bin/tar", "-xf", str(archive_path), "-C", str(extracted)],
            "source commit archive extraction",
        )
        require(
            artifact_sha256(extracted) == SOURCE_TREE_SHA256,
            "retained pre-generation source tree is not the frozen c871 tree",
        )
        validate_generated_source_snapshot(extracted, source_snapshot_path)


def resolve_artifact_path(root: Path, relative: str, label: str) -> Path:
    safe_relative_path(relative, label)
    candidate = root
    parts = PurePosixPath(relative).parts
    for index, part in enumerate(parts):
        candidate = candidate / part
        try:
            metadata = candidate.lstat()
        except OSError as error:
            raise AuditError(f"could not resolve {label} component {part!r}: {error}") from error
        require(not stat.S_ISLNK(metadata.st_mode), f"{label} contains a symlink component")
        if index != len(parts) - 1:
            require(stat.S_ISDIR(metadata.st_mode), f"{label} parent component is not a directory")
    return candidate


def hash_full_artifact(path: Path, hash_mode: str) -> str:
    if hash_mode == "file-sha256":
        return sha256_file(path)
    if hash_mode == "artifact-sha256":
        return artifact_sha256(path)
    require(
        hash_mode == "resolved-package-input-sha256",
        f"unknown full-artifact hash mode: {hash_mode}",
    )
    return resolved_package_sha256(path)


def copy_artifact_snapshot(
    source: Path,
    destination: Path,
    expected_type: str,
    hash_mode: str,
) -> None:
    require_artifact_entry_type(source, expected_type, "full artifact source")
    if hash_mode == "resolved-package-input-sha256":
        destination.mkdir()
        shutil.copytree(source / "artifacts", destination / "artifacts", symlinks=True)
        shutil.copytree(
            source / "checkouts",
            destination / "checkouts",
            symlinks=True,
            ignore=lambda _directory, names: {".git"} & set(names),
        )
        shutil.copyfile(
            source / "workspace-state.json",
            destination / "workspace-state.json",
            follow_symlinks=False,
        )
    elif expected_type == "file":
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination, follow_symlinks=False)
    else:
        shutil.copytree(source, destination, symlinks=True)
    require_artifact_entry_type(destination, expected_type, "private full-artifact snapshot")
    if expected_type == "directory":
        make_tree_owner_writable(destination)
    else:
        os.chmod(destination, destination.stat().st_mode | stat.S_IWUSR)


def make_tree_owner_writable(root: Path) -> None:
    for directory, directory_names, file_names in os.walk(root, followlinks=False):
        for name in directory_names + file_names:
            path = Path(directory) / name
            if not path.is_symlink():
                os.chmod(path, path.stat().st_mode | stat.S_IWUSR)
    os.chmod(root, root.stat().st_mode | stat.S_IWUSR)


def inspect_full_xcresult(
    xcresult_path: Path,
    expected_sha256: str,
    retained_summary: object,
    environment: dict,
    run_id: str,
) -> None:
    reject_tree_symlinks(xcresult_path, f"{run_id} raw xcresult")
    original_before = artifact_sha256(xcresult_path)
    require(original_before == expected_sha256, f"{run_id}: xcresult changed before fresh inspection")
    with tempfile.TemporaryDirectory(
        prefix="plainsong-f2-xcresult-audit.",
        dir="/private/tmp",
    ) as temporary:
        copy = Path(temporary) / "Result.xcresult"
        shutil.copytree(xcresult_path, copy, symlinks=True)
        reject_tree_symlinks(copy, f"{run_id} fresh xcresult copy")
        make_tree_owner_writable(copy)
        require(artifact_sha256(copy) == expected_sha256, f"{run_id}: fresh xcresult copy differs")
        xcresulttool_path = resolve_current_xcresulttool(environment)
        tool_identity = path_identity(xcresulttool_path, "current xcresulttool")
        require(
            resolve_current_xcresulttool(environment) == xcresulttool_path,
            f"{run_id}: xcresulttool identity changed immediately before invocation",
        )
        try:
            completed = subprocess.run(
                [
                    str(xcresulttool_path),
                    "get",
                    "test-results",
                    "summary",
                    "--compact",
                    "--path",
                    str(copy),
                ],
                check=False,
                capture_output=True,
                env=sanitized_subprocess_environment(),
                timeout=XCRESULTTOOL_TIMEOUT_SECONDS,
            )
        except subprocess.TimeoutExpired as error:
            raise AuditError(
                f"{run_id}: xcresulttool timed out after "
                f"{XCRESULTTOOL_TIMEOUT_SECONDS} seconds"
            ) from error
        require(
            path_identity(xcresulttool_path, "post-invocation xcresulttool") == tool_identity
            and sha256_file(xcresulttool_path) == environment["xcresulttoolSHA256"]
            and resolve_current_xcresulttool(environment) == xcresulttool_path,
            f"{run_id}: xcresulttool identity changed across invocation",
        )
        require(
            completed.returncode == 0,
            f"{run_id}: xcresulttool failed on fresh copy: "
            f"{completed.stderr.decode('utf-8', errors='replace').strip()}",
        )
        live_summary = loads_json(completed.stdout, f"{run_id} fresh xcresult summary")
        validate_summary(live_summary, environment, f"{run_id} fresh xcresult summary")
        require(live_summary == retained_summary, f"{run_id}: retained summary differs from fresh xcresult")
    require(artifact_sha256(xcresult_path) == expected_sha256, f"{run_id}: source xcresult was mutated")


def resolve_current_xcresulttool(environment: dict) -> Path:
    selected_data = run_trusted_command(
        ["/usr/bin/xcode-select", "-p"],
        "current xcode-select lookup",
    )
    tool_data = run_trusted_command(
        ["/usr/bin/xcrun", "--find", "xcresulttool"],
        "current xcresulttool lookup",
    )
    try:
        selected = selected_data.decode("utf-8", errors="strict").rstrip("\n")
        tool = tool_data.decode("utf-8", errors="strict").rstrip("\n")
    except UnicodeDecodeError as error:
        raise AuditError(f"current Xcode tool lookup is not UTF-8: {error}") from error
    require("\n" not in selected and selected != "", "current xcode-select returned multiple/empty paths")
    require("\n" not in tool and tool != "", "current xcrun returned multiple/empty paths")
    require(
        selected == environment["selectedDeveloperDir"],
        "current xcode-select developer directory differs from recorded evidence",
    )
    require(
        tool == environment["xcresulttoolPath"],
        "current xcrun xcresulttool path differs from recorded evidence",
    )
    tool_path = Path(tool)
    require(
        tool_path.is_absolute(),
        "current xcrun xcresulttool is not an absolute regular-file path",
    )
    require_artifact_entry_type(tool_path, "file", "current xcrun xcresulttool")
    require(
        sha256_file(tool_path) == environment["xcresulttoolSHA256"],
        "current xcrun xcresulttool digest differs from recorded evidence",
    )
    return tool_path


def verify_full_artifacts(
    artifact_root: Path,
    run_records: list[dict],
    environment: dict,
) -> None:
    require(
        artifact_root.is_absolute()
        and artifact_root.is_dir()
        and not artifact_root.is_symlink()
        and artifact_root.resolve(strict=True) == artifact_root,
        f"--artifact-root is not a real directory: {artifact_root}",
    )
    require_owner_controlled_directory(artifact_root, "full artifact root")
    require_read_only_tree(artifact_root, "full artifact root")
    root_identity = path_identity(artifact_root, "full artifact root")
    original_records: dict[str, dict[str, object]] = {}
    run_artifacts: dict[str, dict[str, dict[str, object]]] = {}
    for record in run_records:
        run_id = record["id"]
        artifacts = record["provenance"]["artifacts"]
        prepared: dict[str, dict[str, object]] = {}
        for name in FULL_ARTIFACT_NAMES:
            item = artifacts[name]
            path = resolve_artifact_path(
                artifact_root,
                item["artifactRootPath"],
                f"{run_id} {name}",
            )
            expected_type = FULL_ARTIFACT_TYPES[name]
            require_artifact_entry_type(path, expected_type, f"{run_id} {name}")
            if name in ("xcresult", "inspectionXcresult"):
                reject_tree_symlinks(path, f"{run_id} {name}")
            identity = path_identity(path, f"{run_id} {name}")
            digest = hash_full_artifact(path, item["hashMode"])
            require(digest == item["sha256"], f"{run_id}: full artifact hash differs for {name}")
            key = str(path)
            candidate = {
                "path": path,
                "relative": item["artifactRootPath"],
                "identity": identity,
                "type": expected_type,
                "hashMode": item["hashMode"],
                "sha256": item["sha256"],
                "xcresult": name in ("xcresult", "inspectionXcresult"),
            }
            if key in original_records:
                require(
                    original_records[key] == candidate,
                    f"{run_id}: shared full artifact has inconsistent provenance: {path}",
                )
            else:
                original_records[key] = candidate
            prepared[name] = candidate
        run_artifacts[run_id] = prepared

    with tempfile.TemporaryDirectory(
        prefix="plainsong-f2-full-artifact-audit.",
        dir="/private/tmp",
    ) as temporary:
        snapshot_root = Path(temporary)
        snapshots: dict[str, Path] = {}
        for index, (key, item) in enumerate(sorted(original_records.items()), start=1):
            snapshot = snapshot_root / f"artifact-{index}"
            copy_artifact_snapshot(
                item["path"],
                snapshot,
                item["type"],
                item["hashMode"],
            )
            if item["xcresult"]:
                reject_tree_symlinks(snapshot, f"private xcresult snapshot {index}")
            require(
                hash_full_artifact(snapshot, item["hashMode"]) == item["sha256"],
                f"private full-artifact snapshot differs: {item['path']}",
            )
            snapshots[key] = snapshot

        verified_source_pairs: set[tuple[str, str]] = set()
        for record in run_records:
            run_id = record["id"]
            prepared = run_artifacts[run_id]
            archive = snapshots[str(prepared["sourceArchive"]["path"])]
            source_snapshot = snapshots[str(prepared["sourceSnapshot"]["path"])]
            source_pair = (str(archive), str(source_snapshot))
            if source_pair not in verified_source_pairs:
                verify_source_archive_commit(
                    archive,
                    source_snapshot,
                    prepared["sourceArchive"]["sha256"],
                    record["build"]["source_tree_sha256"],
                )
                verified_source_pairs.add(source_pair)
            raw_xcresult = snapshots[str(prepared["xcresult"]["path"])]
            inspect_full_xcresult(
                raw_xcresult,
                prepared["xcresult"]["sha256"],
                record["summary"],
                environment,
                run_id,
            )

    for sweep in ("post-audit", "final"):
        require_read_only_tree(artifact_root, f"{sweep} full artifact root")
        require(
            path_identity(artifact_root, f"{sweep} full artifact root")
            == root_identity,
            "full artifact root identity changed during audit",
        )
        for item in original_records.values():
            path = item["path"]
            require(
                resolve_artifact_path(
                    artifact_root,
                    item["relative"],
                    f"{sweep} full artifact",
                )
                == path,
                f"full artifact path changed during audit: {path}",
            )
            require(
                path_identity(path, f"{sweep} full artifact") == item["identity"],
                f"full artifact identity changed during audit: {path}",
            )
            require_artifact_entry_type(path, item["type"], f"{sweep} full artifact")
            if item["xcresult"]:
                reject_tree_symlinks(path, f"{sweep} xcresult")
            require(
                hash_full_artifact(path, item["hashMode"]) == item["sha256"],
                f"full artifact changed during audit: {path}",
            )
            require(
                resolve_artifact_path(
                    artifact_root,
                    item["relative"],
                    f"{sweep} post-hash full artifact",
                )
                == path
                and path_identity(path, f"{sweep} post-hash full artifact")
                == item["identity"],
                f"full artifact identity changed while hashing: {path}",
            )
            require_artifact_entry_type(
                path,
                item["type"],
                f"{sweep} post-hash full artifact",
            )
            if item["xcresult"]:
                reject_tree_symlinks(path, f"{sweep} post-hash xcresult")
        require(
            path_identity(artifact_root, f"{sweep} completed full artifact root")
            == root_identity,
            "full artifact root identity changed during audit",
        )
        require_read_only_tree(
            artifact_root,
            f"{sweep} completed full artifact root",
        )


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


def validate_pack_snapshot(pack_root: Path, artifact_root: Path | None) -> None:
    require(pack_root.is_dir() and not pack_root.is_symlink(), f"pack path is not a directory: {pack_root}")
    inventory = validate_inventory(pack_root)
    manifest_path = pack_file(pack_root, inventory, "manifest.json", "manifest")
    manifest = validate_manifest(load_json(manifest_path, "manifest.json"))

    fixture_path = Path(__file__).resolve().parent.parent / EXPECTED_FIXTURE["path"]
    require(fixture_path.is_file(), f"repository fixture is missing: {fixture_path}")
    require(fixture_path.stat().st_size == FIXTURE_BYTES, "repository fixture byte count differs")
    require(sha256_file(fixture_path) == FIXTURE_SHA256, "repository fixture content differs")
    checker_path = pack_file(
        pack_root,
        inventory,
        manifest["warningChecker"]["path"],
        "retained c871 warning checker",
    )
    require(sha256_file(checker_path) == WARNING_CHECKER_SHA256, "retained warning checker hash differs")

    builds = manifest["builds"]
    require(isinstance(builds, list) and len(builds) == 2, "manifest must contain Debug and Release builds")
    build_records: dict[str, tuple[dict[str, str], str]] = {}
    for index, expected_configuration in enumerate(("Debug", "Release")):
        build = require_keys(builds[index], ("configuration", "manifestPath", "sha256"), f"build {index}")
        require(build["configuration"] == expected_configuration, "build order/configuration differs")
        require_sha256(build["sha256"], f"{expected_configuration} retained build manifest")
        path = pack_file(pack_root, inventory, build["manifestPath"], f"{expected_configuration} build manifest")
        require(sha256_file(path) == build["sha256"], f"{expected_configuration} build manifest hash differs")
        fields = parse_key_values(path, BUILD_KEYS, f"{expected_configuration} build manifest")
        validate_build_manifest(fields, expected_configuration, manifest["environment"])
        require(
            fields["xcodegen_sha256"] == manifest["environment"]["xcodegenSHA256"],
            f"{expected_configuration} build XcodeGen differs from recorded environment",
        )
        build_records[expected_configuration] = (fields, build["sha256"])
    debug_build = build_records["Debug"][0]
    release_build = build_records["Release"][0]
    for key in (
        "repository_root",
        "source_archive_sha256",
        "source_tree_sha256",
        "resolved_package_input_sha256",
        "xcodegen_path",
        "xcodegen_sha256",
    ):
        require(debug_build[key] == release_build[key], f"Debug/Release build provenance differs for {key}")

    runs = manifest["runs"]
    require(isinstance(runs, list) and len(runs) == 6, "manifest must contain exactly six runs")
    run_records = []
    for index, expected_id in enumerate(EXPECTED_RUN_IDS):
        run = require_keys(
            runs[index],
            ("id", "configuration", "ordinal", "directory", "files"),
            f"run {index}",
        )
        expected_configuration = "Debug" if index < 3 else "Release"
        expected_ordinal = index + 1 if index < 3 else index - 2
        require(run["id"] == expected_id, f"run order differs at {index}")
        require(run["configuration"] == expected_configuration, f"{expected_id}: configuration differs")
        require(run["ordinal"] == expected_ordinal, f"{expected_id}: ordinal differs")
        expected_directory = f"runs/{expected_id}"
        require(run["directory"] == expected_directory, f"{expected_id}: directory differs")
        files = require_keys(run["files"], tuple(RUN_FILE_NAMES), f"{expected_id} files")
        for key, name in RUN_FILE_NAMES.items():
            require(files[key] == f"{expected_directory}/{name}", f"{expected_id}: {key} path differs")
        build, build_sha = build_records[expected_configuration]
        run_records.append(
            validate_run(
                pack_root,
                inventory,
                run,
                build,
                build_sha,
                manifest["environment"],
            )
        )

    for field, label in (
        ("phaseId", "warning phase UUIDs"),
        ("rawLogSHA256", "raw-log digests"),
        ("xcresultSHA256", "xcresult digests"),
    ):
        values = [record[field] for record in run_records]
        require(len(set(values)) == 6, f"six-run {label} are not unique")
    for previous, current in zip(run_records, run_records[1:]):
        require(
            previous["summaryFinish"] <= current["summaryStart"],
            f"six-run chronology overlaps or is out of order: "
            f"{previous['id']} then {current['id']}",
        )

    if artifact_root is not None:
        verify_full_artifacts(artifact_root, run_records, manifest["environment"])
        artifact_mode = "verified"
        audit_mode = "compact-plus-full-artifact"
    else:
        artifact_mode = "provenance-only"
        audit_mode = "compact"

    metric_names = tuple(EXPECTED_BUDGETS)
    aggregates: dict[str, dict[str, Decimal]] = {}
    for configuration in ("Debug", "Release"):
        selected = [record for record in run_records if record["configuration"] == configuration]
        aggregates[configuration] = {
            metric: odd_median([record["timings"][metric] for record in selected])
            for metric in metric_names
        }
    slowest_debug = {
        metric: max(
            record["timings"][metric]
            for record in run_records
            if record["configuration"] == "Debug"
        )
        for metric in metric_names
    }

    result = "PASS" if artifact_root is not None else "PARTIAL"
    print(
        f"F2 RETAINED EVIDENCE AUDIT {result} "
        f"mode={audit_mode} full-artifacts={artifact_mode} runs=6 source={SOURCE_COMMIT}"
    )
    proxy_result = "PASS" if artifact_root is not None else "OPEN"
    print(
        f"F2 PROXY {proxy_result} query-completion "
        f"debug-medians-ms={aggregates['Debug']['zeroQueryCompletion']}/"
        f"{aggregates['Debug']['sparseQueryCompletion']}/"
        f"{aggregates['Debug']['denseTruncatedQueryCompletion']} "
        f"release-medians-ms={aggregates['Release']['zeroQueryCompletion']}/"
        f"{aggregates['Release']['sparseQueryCompletion']}/"
        f"{aggregates['Release']['denseTruncatedQueryCompletion']}"
    )
    print(
        f"F2 PROXY {proxy_result} native-edit-admission "
        f"debug-median-ms={aggregates['Debug']['nativeEditAdmission']} "
        f"release-median-ms={aggregates['Release']['nativeEditAdmission']}"
    )
    print(
        f"F2 PROXY {proxy_result} root-state-update-receipt "
        f"debug-median-ms={aggregates['Debug']['rootStateUpdateReceipt']} "
        f"release-median-ms={aggregates['Release']['rootStateUpdateReceipt']}"
    )
    headroom = "/".join(
        f"{(EXPECTED_BUDGETS[metric] / slowest_debug[metric]):.2f}"
        for metric in metric_names
    )
    print(f"F2 PROXY {proxy_result} DEBUG HEADROOM budget-over-slowest-run={headroom}")
    if artifact_root is not None:
        print("F2 WARNING PHASE PASS pre=3 measured=0 post=0 negative-control=pass runs=6")
    else:
        print(
            "F2 WARNING PHASE OPEN compact-records-validated=true "
            "full-artifact-verification-required=true runs=6"
        )
    print("F2 OPEN full-keystroke-to-screen")
    print("F2 OPEN F8-highlight-apply-clear")
    print("F2 OPEN F9")
    print("F2 OPEN combined-tip")


def validate_pack(pack_root: Path, artifact_root: Path | None) -> None:
    require(
        pack_root.is_absolute()
        and pack_root.is_dir()
        and not pack_root.is_symlink()
        and pack_root.resolve(strict=True) == pack_root,
        f"pack path is not a real canonical directory: {pack_root}",
    )
    require_owner_controlled_directory(pack_root, "evidence pack root")
    root_identity = path_identity(pack_root, "evidence pack root")
    initial_inventory = validate_inventory(pack_root)
    output = io.StringIO()
    with tempfile.TemporaryDirectory(
        prefix="plainsong-f2-pack-audit.",
        dir="/private/tmp",
    ) as temporary:
        snapshot = Path(temporary) / "pack"
        shutil.copytree(pack_root, snapshot, symlinks=True)
        make_tree_owner_writable(snapshot)
        require(
            validate_inventory(snapshot) == initial_inventory,
            "private evidence-pack snapshot differs from the original inventory",
        )
        with contextlib.redirect_stdout(output):
            validate_pack_snapshot(snapshot, artifact_root)
    require(
        path_identity(pack_root, "post-audit evidence pack root") == root_identity,
        "evidence pack root identity changed during audit",
    )
    require(
        validate_inventory(pack_root) == initial_inventory,
        "evidence pack bytes or inventory changed during audit",
    )
    print(output.getvalue(), end="")


def canonical_directory_argument(path: Path, label: str) -> Path:
    candidate = path if path.is_absolute() else Path.cwd() / path
    try:
        resolved = candidate.resolve(strict=True)
    except OSError as error:
        raise AuditError(f"could not resolve {label} {path}: {error}") from error
    require(
        resolved == candidate,
        f"{label} must name a real canonical directory without symlink components: {path}",
    )
    return candidate


def parse_arguments() -> argparse.Namespace:
    repository_root = Path(__file__).resolve().parent.parent
    default_pack = (
        repository_root
        / "docs"
        / "performance-evidence"
        / "editor-find-f2"
        / "2026-08-08-c871ddf5"
    )
    parser = argparse.ArgumentParser(
        description="Audit retained compact F2 performance evidence without overstating its scope."
    )
    parser.add_argument(
        "pack",
        nargs="?",
        type=Path,
        default=default_pack,
        help=f"evidence-pack directory (default: {default_pack})",
    )
    parser.add_argument(
        "--artifact-root",
        type=Path,
        help="optional root containing every full artifactRootPath named by run provenance",
    )
    parser.add_argument(
        "--allow-partial",
        action="store_true",
        help=(
            "return zero after a compact-only PARTIAL/OPEN audit; without this flag "
            f"a valid compact-only audit exits {PARTIAL_AUDIT_EXIT_STATUS}"
        ),
    )
    arguments = parser.parse_args()
    if arguments.allow_partial and arguments.artifact_root is not None:
        parser.error("--allow-partial cannot be combined with --artifact-root")
    try:
        arguments.pack = canonical_directory_argument(arguments.pack, "evidence pack")
        if arguments.artifact_root is not None:
            arguments.artifact_root = canonical_directory_argument(
                arguments.artifact_root,
                "full artifact root",
            )
    except AuditError as error:
        parser.error(str(error))
    return arguments


def main() -> None:
    arguments = parse_arguments()
    try:
        validate_pack(arguments.pack, arguments.artifact_root)
    except (AuditError, OSError, ValueError) as error:
        print(f"F2 RETAINED EVIDENCE AUDIT FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
    if arguments.artifact_root is None and not arguments.allow_partial:
        print(
            "F2 RETAINED EVIDENCE AUDIT OPEN: compact validation is partial; "
            "pass --allow-partial to accept that limited scope or provide --artifact-root",
            file=sys.stderr,
        )
        raise SystemExit(PARTIAL_AUDIT_EXIT_STATUS)


if __name__ == "__main__":
    main()
