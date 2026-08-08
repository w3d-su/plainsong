from __future__ import annotations

from .context import (
    RUN_FILES,
    SOURCE_COMMIT,
    SOURCE_SUFFIXES,
    SUMMARY_COMMAND,
    Path,
    shutil,
)
from .io import (
    canonical_file,
    full_artifact,
    parse_key_values,
    parse_tokens,
    require,
    sha256_bytes,
    summary_from_fresh_copy,
    write_json,
    write_key_values,
)

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
        canonical_file(source, f"{run_id} {key} source")
        destination = run_root / RUN_FILES[key]
        shutil.copyfile(source, destination)
        files[key] = f"runs/{run_id}/{RUN_FILES[key]}"

    evidence = parse_key_values(run_root / RUN_FILES["evidenceManifest"])
    warning_lines = (run_root / RUN_FILES["warningCheck"]).read_text(
        encoding="utf-8"
    ).splitlines()
    require(len(warning_lines) == 2, f"{run_id} warning check must contain two lines")
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
