from __future__ import annotations

from .context import (
    EXPECTED_BOUNDARIES,
    EXPECTED_BUDGETS,
    EXPECTED_BUILD_IDENTITIES,
    EXPECTED_FIXTURE,
    FULL_ARTIFACT_NAMES,
    RESOLVED_PACKAGE_INPUT_SHA256,
    SOURCE_ARCHIVE_SHA256,
    SOURCE_COMMIT,
    SOURCE_TREE_SHA256,
    WARNING_CHECKER_SHA256,
    XCODEGEN_SHA256,
    Decimal,
    PurePosixPath,
)
from .core import require, require_keys, require_sha256, safe_relative_path

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
