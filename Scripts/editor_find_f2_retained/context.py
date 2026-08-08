"""Pinned identities and standard-library dependencies for the F2 audit."""

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

SCRIPT_DIRECTORY = Path(__file__).resolve().parent.parent
REPOSITORY_ROOT = SCRIPT_DIRECTORY.parent

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
