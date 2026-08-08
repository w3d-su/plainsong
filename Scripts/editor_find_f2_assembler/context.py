"""Constants and standard-library dependencies for pack assembly."""

from __future__ import annotations

import argparse
import atexit
import ctypes
import hashlib
import json
import os
import pwd
import re
import shutil
import stat
import subprocess
import tempfile
from pathlib import Path

SOURCE_COMMIT = "c871ddf5c66c17f03fd9456b53f79411f9b2e979"
FIXTURE_SHA256 = "d174f48ea6175db568abe44e5b71e82ee92f1cf9c0ed081d8f8308cc1961d247"
WARNING_CHECKER_SHA256 = (
    "385e83e5f0f30192ee9ff3f429fe342b5e7a52dabd5b784b3b998a0800956aac"
)
HISTORICAL_CAPTURE_HELPER_SHA256 = (
    "c5f36fa61dc8cd3c9c465f61ec10695b3d21016bb16058f0ab66198f234597ef"
)
EXPECTED_PACK_INVENTORY_SHA256 = (
    "d2f1497b19c37db3b49b5028292871fe6194752d94de05f55d5e7b6337767e22"
)
REFERENCE_SCRIPT_SHA256 = {
    "build-editor-find-f2-performance-gate.sh": (
        "02249b49aabc80286cb17e668edebfeef987a9ae4abe75d6ee3aeceeeb084598"
    ),
    "capture-editor-find-f2-log.py": (
        "b33abb474ec66b6814f6a1b753841102a394bb4af9dab65b34f0528301abe53e"
    ),
    "check-editor-find-f2-warning-phase.py": WARNING_CHECKER_SHA256,
    "hash-editor-find-f2-artifact.py": (
        "12a513db0cee885572ae03d696b24d7be1a86f13860ca35a7fbbdaadb40b113e"
    ),
    "run-editor-find-f2-performance-gate.sh": (
        "90e5aa9edd01a96132b80a092421c2cfc47c7e6d2944f1876bf8ddcf76edea8d"
    ),
}
EXPECTED_BUILD_MANIFEST_SHA256 = {
    "Debug": "fe374662a09ccb452ce55f0796740c96b66624483afe55aa53fcff2c8dfb3510",
    "Release": "5ca8c353ad557267745566ec597ba5971b024afb2796237158b062e3fcdd6a8a",
}
XCRESULTTOOL = Path(
    "/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcresulttool"
)
XCRESULTTOOL_SHA256 = (
    "7aada4a60aad3de62bc7fbda7afd990e53d8335710d1a8792fd279d42491a5c9"
)
SUMMARY_COMMAND = (
    f"{XCRESULTTOOL} get test-results summary --compact --path FRESH_COPY"
)
RUNS = (
    ("debug-1", "debug-1", "Debug", 1),
    ("debug-2", "debug-2", "Debug", 2),
    ("debug-3", "debug-3-retry1", "Debug", 3),
    ("release-1", "release-1", "Release", 1),
    ("release-2", "release-2", "Release", 2),
    ("release-3", "release-3", "Release", 3),
)
RUN_FILES = {
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
SOURCE_SUFFIXES = {
    "preflight": ".preflight.txt",
    "preflightDigest": ".preflight.txt.sha256",
    "competitionMonitor": ".competition-monitor.log",
    "competitionMonitorDigest": ".competition-monitor.log.sha256",
    "competitionMonitorSamples": ".competition-monitor.samples.txt",
    "competitionMonitorSamplesDigest": ".competition-monitor.samples.txt.sha256",
    "runOwnedProcesses": ".run-owned-processes.log",
    "runOwnedProcessesDigest": ".run-owned-processes.log.sha256",
    "competitionMonitorStatus": ".competition-monitor.status.txt",
    "competitionMonitorStatusDigest": ".competition-monitor.status.txt.sha256",
    "rawLog": ".log",
    "rawLogDigest": ".log.sha256",
    "warningCheck": ".warning-check.txt",
    "warningCheckDigest": ".warning-check.txt.sha256",
    "evidenceManifest": ".evidence-manifest.txt",
    "outerLog": ".outer.log",
    "outerLogDigest": ".outer.log.sha256",
    "outerStatus": ".outer.status.txt",
    "postflight": ".postflight.txt",
    "postflightDigest": ".postflight.txt.sha256",
}

SCRIPT_DIRECTORY = Path(__file__).resolve().parent.parent
