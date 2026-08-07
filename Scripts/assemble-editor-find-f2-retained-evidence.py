#!/usr/bin/python3

"""Assemble the compact audit pack for the retained c871 F2 baseline."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path


SOURCE_COMMIT = "c871ddf5c66c17f03fd9456b53f79411f9b2e979"
FIXTURE_SHA256 = "d174f48ea6175db568abe44e5b71e82ee92f1cf9c0ed081d8f8308cc1961d247"
WARNING_CHECKER_SHA256 = (
    "385e83e5f0f30192ee9ff3f429fe342b5e7a52dabd5b784b3b998a0800956aac"
)
XCRESULTTOOL = Path(
    "/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcresulttool"
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


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def parse_key_values(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        key, value = line.split("=", 1)
        result[key] = value
    return result


def parse_tokens(line: str) -> dict[str, str]:
    return dict(token.split("=", 1) for token in line.split() if "=" in token)


def write_json(path: Path, value: object) -> None:
    path.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def write_key_values(path: Path, values: tuple[tuple[str, str], ...]) -> None:
    path.write_text(
        "".join(f"{key}={value}\n" for key, value in values),
        encoding="utf-8",
    )


def make_tree_writable(root: Path) -> None:
    for directory, directory_names, file_names in os.walk(root):
        for name in directory_names + file_names:
            path = Path(directory) / name
            if not path.is_symlink():
                path.chmod(path.stat().st_mode | 0o200)
    root.chmod(root.stat().st_mode | 0o200)


def summary_from_fresh_copy(xcresult: Path) -> bytes:
    with tempfile.TemporaryDirectory(
        prefix="plainsong-f2-pack-summary.",
        dir="/private/tmp",
    ) as temporary:
        copy = Path(temporary) / "Result.xcresult"
        shutil.copytree(xcresult, copy, symlinks=True)
        make_tree_writable(copy)
        completed = subprocess.run(
            [
                str(XCRESULTTOOL),
                "get",
                "test-results",
                "summary",
                "--compact",
                "--path",
                str(copy),
            ],
            check=False,
            capture_output=True,
            env={
                "HOME": os.path.expanduser("~"),
                "LANG": "C",
                "LC_ALL": "C",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "TMPDIR": "/private/tmp",
                "USER": os.environ["USER"],
                "LOGNAME": os.environ["USER"],
            },
            timeout=120,
        )
        if completed.returncode != 0:
            raise RuntimeError(
                "xcresulttool summary failed: "
                + completed.stderr.decode("utf-8", errors="replace")
            )
        json.loads(completed.stdout.decode("utf-8", errors="strict"))
        return completed.stdout


def full_artifact(
    original: str,
    relative: str,
    mode: str,
    digest: str,
) -> dict[str, str]:
    return {
        "originalPath": original,
        "artifactRootPath": relative,
        "hashMode": mode,
        "sha256": digest,
    }


def assemble_run(
    source_root: Path,
    full_root: Path,
    pack_root: Path,
    run_id: str,
    prefix_name: str,
    configuration: str,
    ordinal: int,
    build: dict[str, str],
    build_manifest_sha256: str,
) -> dict[str, object]:
    source_prefix = source_root / prefix_name
    run_root = pack_root / "runs" / run_id
    run_root.mkdir(parents=True)
    files: dict[str, str] = {}
    for key, suffix in SOURCE_SUFFIXES.items():
        source = Path(str(source_prefix) + suffix)
        destination = run_root / RUN_FILES[key]
        shutil.copyfile(source, destination)
        files[key] = f"runs/{run_id}/{RUN_FILES[key]}"

    evidence = parse_key_values(run_root / RUN_FILES["evidenceManifest"])
    warning_lines = (run_root / RUN_FILES["warningCheck"]).read_text(
        encoding="utf-8"
    ).splitlines()
    source_tokens = parse_tokens(warning_lines[0])
    raw_xcresult = full_root / "runs" / run_id / "raw.xcresult"
    summary_data = summary_from_fresh_copy(raw_xcresult)
    summary_path = run_root / RUN_FILES["xcresultSummary"]
    summary_path.write_bytes(summary_data)
    files["xcresultSummary"] = f"runs/{run_id}/{RUN_FILES['xcresultSummary']}"
    write_key_values(
        run_root / RUN_FILES["summaryProvenance"],
        (
            ("format", "1"),
            ("source_commit", SOURCE_COMMIT),
            ("configuration", configuration),
            ("run_id", run_id),
            (
                "command",
                SUMMARY_COMMAND,
            ),
            ("xcresult_sha256", evidence["xcresult_sha256"]),
            ("inspection_copy_input_sha256", evidence["xcresult_sha256"]),
            ("inspection_copy_disposition", "deleted-after-summary-read"),
            ("summary_sha256", sha256_bytes(summary_data)),
            ("summary_bytes", str(len(summary_data))),
            ("xcresulttool_exit_status", "0"),
        ),
    )
    files["summaryProvenance"] = f"runs/{run_id}/{RUN_FILES['summaryProvenance']}"

    configuration_key = configuration.lower()
    xctestrun_name = Path(build["xctestrun_relative_path"]).name
    provenance = {
        "format": 1,
        "sourceCommit": SOURCE_COMMIT,
        "configuration": configuration,
        "runId": run_id,
        "retainedInPack": False,
        "retainedAtArtifactRoot": True,
        "verificationScope": "owner-local-full-artifact",
        "artifacts": {
            "sourceArchive": full_artifact(
                build["source_archive_path"],
                "source/c871ddf.source.tar",
                "file-sha256",
                build["source_archive_sha256"],
            ),
            "sourceSnapshot": full_artifact(
                build["source_snapshot_path"],
                f"source/{configuration_key}.source",
                "artifact-sha256",
                build["build_input_sha256"],
            ),
            "resolvedPackageInput": full_artifact(
                build["package_input_path"],
                "packages/resolved",
                "resolved-package-input-sha256",
                build["resolved_package_input_sha256"],
            ),
            "buildManifest": full_artifact(
                evidence["build_manifest_path"],
                f"builds/{configuration_key}/build-manifest.txt",
                "file-sha256",
                build_manifest_sha256,
            ),
            "hostBundle": full_artifact(
                source_tokens["frozen-products"]
                + f"/Build/Products/{configuration}/Plainsong.app",
                f"builds/{configuration_key}/Plainsong.app",
                "artifact-sha256",
                build["host_bundle_sha256"],
            ),
            "xctestrun": full_artifact(
                source_tokens["frozen-products"]
                + "/"
                + build["xctestrun_relative_path"],
                f"builds/{configuration_key}/{xctestrun_name}",
                "artifact-sha256",
                build["xctestrun_sha256"],
            ),
            "rawLog": full_artifact(
                evidence["raw_log_path"],
                f"runs/{run_id}/raw.log",
                "file-sha256",
                evidence["raw_log_sha256"],
            ),
            "xcresult": full_artifact(
                evidence["xcresult_path"],
                f"runs/{run_id}/raw.xcresult",
                "artifact-sha256",
                evidence["xcresult_sha256"],
            ),
            "inspectionXcresult": full_artifact(
                evidence["xcresult_inspection_path"],
                f"runs/{run_id}/inspection.xcresult",
                "artifact-sha256",
                evidence["xcresult_inspection_result_sha256"],
            ),
        },
    }
    write_json(run_root / RUN_FILES["fullArtifactProvenance"], provenance)
    files["fullArtifactProvenance"] = (
        f"runs/{run_id}/{RUN_FILES['fullArtifactProvenance']}"
    )
    return {
        "id": run_id,
        "configuration": configuration,
        "ordinal": ordinal,
        "directory": f"runs/{run_id}",
        "files": files,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source_run_root", type=Path)
    parser.add_argument("full_artifact_root", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    source_root = args.source_run_root.resolve(strict=True)
    full_root = args.full_artifact_root.resolve(strict=True)
    output = args.output
    if output.exists() or output.is_symlink():
        raise SystemExit(f"refusing existing output: {output}")
    output.mkdir(parents=True, mode=0o700)

    reference = output / "reference"
    reference.mkdir()
    repository_root = Path(__file__).resolve().parent.parent
    debug_scripts = full_root / "source" / "debug.source" / "Scripts"
    release_scripts = full_root / "source" / "release.source" / "Scripts"
    for name in (
        "build-editor-find-f2-performance-gate.sh",
        "capture-editor-find-f2-log.py",
        "check-editor-find-f2-warning-phase.py",
        "hash-editor-find-f2-artifact.py",
        "run-editor-find-f2-performance-gate.sh",
    ):
        debug_script = debug_scripts / name
        release_script = release_scripts / name
        if sha256_file(debug_script) != sha256_file(release_script):
            raise RuntimeError(
                f"retained Debug/Release source scripts differ: {name}"
            )
        shutil.copyfile(debug_script, reference / name)
    shutil.copyfile(
        repository_root / "Scripts" / "capture-editor-find-f2-authoritative-run.sh",
        reference / "capture-editor-find-f2-authoritative-run.sh",
    )

    builds_root = output / "builds"
    builds_root.mkdir()
    build_records: dict[str, tuple[dict[str, str], str, str]] = {}
    for configuration in ("Debug", "Release"):
        key = configuration.lower()
        source = full_root / "builds" / key / "build-manifest.txt"
        destination = builds_root / f"{key}-build-manifest.txt"
        shutil.copyfile(source, destination)
        digest = sha256_file(destination)
        build_records[configuration] = (
            parse_key_values(destination),
            digest,
            f"builds/{key}-build-manifest.txt",
        )

    runs = []
    for run_id, prefix, configuration, ordinal in RUNS:
        build, build_digest, _ = build_records[configuration]
        runs.append(
            assemble_run(
                source_root,
                full_root,
                output,
                run_id,
                prefix,
                configuration,
                ordinal,
                build,
                build_digest,
            )
        )

    manifest = {
        "format": 1,
        "gate": "editor-find-f2-retained-evidence",
        "sourceCommit": SOURCE_COMMIT,
        "environment": {
            "recordedAt": "2026-08-07T19:35:36Z",
            "timeZone": "Asia/Taipei",
            "macOSVersion": "27.0",
            "macOSBuild": "26A5388g",
            "xcodeVersion": "27.0",
            "xcodeBuild": "27A5194q",
            "selectedDeveloperDir": "/Applications/Xcode-beta.app/Contents/Developer",
            "macOSSDKPath": "/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk",
            "macOSSDKVersion": "27.0",
            "macOSSDKBuild": "26A5353p",
            "xcodegenVersion": "2.45.4",
            "xcodegenSHA256": "3b483413a801394b00adb2fabf3c06ff8f800c73c8698e1f9a9d8a95d73939ef",
            "xcresulttoolPath": str(XCRESULTTOOL),
            "xcresulttoolSHA256": "7aada4a60aad3de62bc7fbda7afd990e53d8335710d1a8792fd279d42491a5c9",
            "architecture": "arm64",
            "machineModel": "MacBookPro18,3",
            "memoryBytes": 17179869184,
            "physicalCPUCount": 8,
            "logicalCPUCount": 8,
        },
        "fixture": {
            "path": "Fixtures/large-1mb.md",
            "bytes": 1048962,
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
                    "first": {"location": 1048904, "length": 24, "line": 33140},
                    "last": {"location": 1048904, "length": 24, "line": 33140},
                },
                "denseTruncated": {
                    "query": "section",
                    "retained": 10000,
                    "truncated": True,
                    "overflowOrdinal": 10001,
                    "first": {"location": 399, "length": 7, "line": 15},
                    "last": {"location": 914752, "length": 7, "line": 28901},
                },
            },
        },
        "warningChecker": {
            "path": "reference/check-editor-find-f2-warning-phase.py",
            "sha256": WARNING_CHECKER_SHA256,
        },
        "budgetsMilliseconds": {
            "zeroQueryCompletion": 400,
            "sparseQueryCompletion": 400,
            "denseTruncatedQueryCompletion": 1100,
            "nativeEditAdmission": 5,
            "rootStateUpdateReceipt": 15,
        },
        "builds": [
            {
                "configuration": configuration,
                "manifestPath": build_records[configuration][2],
                "sha256": build_records[configuration][1],
            }
            for configuration in ("Debug", "Release")
        ],
        "runs": runs,
        "boundaries": {
            "queryCompletionProxy": "pass",
            "nativeEditAdmissionProxy": "pass",
            "rootStateUpdateReceiptProxy": "pass",
            "warningPhase": "audited",
            "fullKeystrokeToScreen": "open",
            "f8HighlightApplyClear": "open",
            "f9": "open",
            "combinedTip": "open",
        },
    }
    write_json(output / "manifest.json", manifest)
    shutil.copyfile(
        full_root.parent / "environment-before.log",
        output / "environment-before.log",
    )
    (output / "README.md").write_text(
        "# Phase 3 editor-find F2 retained evidence\n\n"
        "This compact pack retains every raw text record and a cryptographic inventory. "
        "It omits large build and xcresult bundles; compact-only audit is therefore "
        "PARTIAL/OPEN. Full PASS additionally requires the owner-local, read-only "
        "artifact root documented in docs/perf-log.md. Loss of that root invalidates "
        "the full baseline and requires six fresh runs. The full root is not replicated "
        "off this Mac, so the overall F2 retention gate remains open.\n",
        encoding="utf-8",
    )
    (output / "commands.txt").write_text(
        "measured-source=c871ddf5c66c17f03fd9456b53f79411f9b2e979\n"
        "capture-helper-sha256="
        + sha256_file(reference / "capture-editor-find-f2-authoritative-run.sh")
        + "\n"
        "audit-compact=python3 Scripts/check-editor-find-f2-retained-evidence.py PACK --allow-partial\n"
        "audit-full=python3 Scripts/check-editor-find-f2-retained-evidence.py PACK --artifact-root OWNER_LOCAL_ROOT\n",
        encoding="utf-8",
    )

    files = sorted(
        path.relative_to(output).as_posix()
        for path in output.rglob("*")
        if path.is_file() and path.name != "SHA256SUMS"
    )
    (output / "SHA256SUMS").write_text(
        "".join(f"{sha256_file(output / relative)}  {relative}\n" for relative in files),
        encoding="ascii",
    )
    print(output)


if __name__ == "__main__":
    main()
