from __future__ import annotations

from .context import (
    EXPECTED_BUILD_MANIFEST_SHA256,
    EXPECTED_PACK_INVENTORY_SHA256,
    FIXTURE_SHA256,
    HISTORICAL_CAPTURE_HELPER_SHA256,
    REFERENCE_SCRIPT_SHA256,
    RUNS,
    SOURCE_COMMIT,
    WARNING_CHECKER_SHA256,
    XCRESULTTOOL,
    Path,
    argparse,
    shutil,
)
from .io import (
    canonical_directory,
    canonical_file,
    output_directory,
    parse_key_values,
    publish_output,
    require,
    sha256_file,
    write_json,
)
from .run import assemble_run

def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source_run_root", type=Path)
    parser.add_argument("full_artifact_root", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument(
        "--historical-capture-helper",
        required=True,
        type=Path,
        help="exact immutable c5f36fa historical capture helper used by these six runs",
    )
    args = parser.parse_args()
    source_root = canonical_directory(args.source_run_root, "source-run root")
    full_root = canonical_directory(args.full_artifact_root, "full-artifact root")
    historical_capture_helper = canonical_file(
        args.historical_capture_helper,
        "historical capture helper",
    )
    require(
        sha256_file(historical_capture_helper) == HISTORICAL_CAPTURE_HELPER_SHA256,
        "historical capture helper differs from the measured c5f36fa bytes",
    )
    output = output_directory(args.output, (source_root, full_root))

    reference = output / "reference"
    reference.mkdir()
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
        canonical_file(debug_script, f"Debug historical reference {name}")
        canonical_file(release_script, f"Release historical reference {name}")
        if sha256_file(debug_script) != sha256_file(release_script):
            raise RuntimeError(
                f"retained Debug/Release source scripts differ: {name}"
            )
        if sha256_file(debug_script) != REFERENCE_SCRIPT_SHA256[name]:
            raise RuntimeError(f"historical reference identity differs: {name}")
        shutil.copyfile(debug_script, reference / name)
    shutil.copyfile(
        historical_capture_helper,
        reference / "capture-editor-find-f2-authoritative-run.sh",
    )

    builds_root = output / "builds"
    builds_root.mkdir()
    build_records: dict[str, tuple[dict[str, str], str, str]] = {}
    for configuration in ("Debug", "Release"):
        key = configuration.lower()
        source = full_root / "builds" / key / "build-manifest.txt"
        canonical_file(source, f"{configuration} build manifest")
        destination = builds_root / f"{key}-build-manifest.txt"
        shutil.copyfile(source, destination)
        digest = sha256_file(destination)
        require(
            digest == EXPECTED_BUILD_MANIFEST_SHA256[configuration],
            f"{configuration} build manifest differs from the measured identity",
        )
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
    environment_log = canonical_file(
        full_root.parent / "environment-before.log",
        "environment log",
    )
    shutil.copyfile(environment_log, output / "environment-before.log")
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
    inventory_path = output / "SHA256SUMS"
    inventory_path.write_text(
        "".join(f"{sha256_file(output / relative)}  {relative}\n" for relative in files),
        encoding="ascii",
    )
    require(
        sha256_file(inventory_path) == EXPECTED_PACK_INVENTORY_SHA256,
        "assembled pack differs from the frozen c871 inventory",
    )
    print(publish_output(output))
