"""Build compact and full F2 retained-evidence roots from six captures."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Callable

from .artifact_hash import hash_artifact
from .builder_inputs import FullArtifactInput, RunInput, load_run_input
from .builder_io import (
    DestinationRegistry,
    copy_file,
    copy_resolved_package,
    copy_tree,
    create_fresh_root,
    remove_fresh_root,
    write_exclusive,
)
from .builder_summary import xcresult_summary
from .errors import require
from .pack import RUN_FILES, validate_pack
from .schema import (
    CURRENT_MANIFEST_FORMAT,
    EvidenceSchema,
    auditor_paths_for_manifest,
    load_json_bytes,
    load_schema,
    tooling_digest,
)
from .strict_io import sha256_file, strict_pack_files

SummaryProvider = Callable[[Path], bytes]
SHARED_ARTIFACTS = {
    "sourceArchive", "sourceSnapshot", "resolvedPackageInput",
    "buildManifest", "hostBundle", "xctestrun",
}


def _json_bytes(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def _artifact_digest(path: Path, mode: str) -> str:
    return sha256_file(path) if mode == "file-sha256" else hash_artifact(
        path,
        mode == "resolved-package-input-sha256",
    )


class ArtifactStore:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.registry = DestinationRegistry(root)
        self.shared: dict[tuple[str, str, str, str], str] = {}

    def retain(self, run_id: str, name: str, artifact: FullArtifactInput) -> str:
        key = (name, artifact.kind, artifact.hash_mode, artifact.expected_sha256)
        if name in SHARED_ARTIFACTS and key in self.shared:
            relative = self.shared[key]
            require(
                _artifact_digest(self.root / relative, artifact.hash_mode) == artifact.expected_sha256,
                f"deduplicated artifact changed: {name}",
            )
            return relative
        relative = (
            f"frozen/{name}/{artifact.expected_sha256}"
            if name in SHARED_ARTIFACTS
            else f"runs/{run_id}/{name}"
        )
        destination = self.root / relative
        if artifact.kind == "file":
            copy_file(artifact.path, destination, self.registry)
        elif artifact.hash_mode == "resolved-package-input-sha256":
            copy_resolved_package(artifact.path, destination, self.registry)
        else:
            copy_tree(artifact.path, destination, self.registry)
        require(
            _artifact_digest(destination, artifact.hash_mode) == artifact.expected_sha256,
            f"retained artifact hash differs: {run_id} {name}",
        )
        if name in SHARED_ARTIFACTS:
            self.shared[key] = relative
        return relative


def _copy_tooling(
    pack_root: Path,
    registry: DestinationRegistry,
    schema: EvidenceSchema,
) -> list[dict[str, str]]:
    scripts = schema.path.parent.parent
    paths = tuple(
        dict.fromkeys(
            schema.capture_tooling_paths
            + auditor_paths_for_manifest(schema, CURRENT_MANIFEST_FORMAT)
        )
    )
    records: list[dict[str, str]] = []
    for relative in paths:
        destination_relative = f"reference/{relative}"
        destination = pack_root / destination_relative
        copy_file(scripts / relative, destination, registry)
        records.append({"path": destination_relative, "sha256": sha256_file(destination)})
    return records


def _retain_full_artifacts(
    run: RunInput,
    store: ArtifactStore,
) -> dict[str, dict[str, str]]:
    records: dict[str, dict[str, str]] = {}
    for name, artifact in run.full_artifacts.items():
        relative = store.retain(run.run_id, name, artifact)
        records[name] = {
            "originalPath": str(artifact.path),
            "artifactRootPath": relative,
            "hashMode": artifact.hash_mode,
            "sha256": artifact.expected_sha256,
        }
    return records


def _copy_run(
    run: RunInput,
    pack_root: Path,
    pack_registry: DestinationRegistry,
    store: ArtifactStore,
    schema: EvidenceSchema,
    summary_provider: SummaryProvider,
) -> dict[str, str]:
    directory = pack_root / "runs" / run.run_id
    for key, source in run.compact_files.items():
        copy_file(source, directory / RUN_FILES[key], pack_registry)
    summary_value = load_json_bytes(summary_provider(run.inspection_xcresult), f"{run.run_id} summary")
    write_exclusive(
        directory / RUN_FILES["xcresultSummary"],
        _json_bytes(summary_value),
        pack_registry,
    )
    provenance = {
        "format": 1,
        "sourceCommit": schema.source_commit,
        "configuration": run.configuration,
        "runId": run.run_id,
        "retainedInPack": False,
        "retainedAtArtifactRoot": True,
        "verificationScope": "owner-local-full-artifact",
        "artifacts": _retain_full_artifacts(run, store),
    }
    write_exclusive(
        directory / RUN_FILES["fullArtifactProvenance"],
        _json_bytes(provenance),
        pack_registry,
    )
    return {
        "id": run.run_id,
        "configuration": run.configuration,
        "directory": f"runs/{run.run_id}",
        "captureToolingSHA256": tooling_digest(
            schema.path.parent.parent,
            schema.capture_tooling_paths,
        ),
    }


def _write_inventory(root: Path, registry: DestinationRegistry) -> None:
    files = sorted(strict_pack_files(root))
    require("SHA256SUMS" not in files, "SHA256SUMS appeared before sealing")
    data = "".join(f"{sha256_file(root / relative)}  {relative}\n" for relative in files)
    write_exclusive(root / "SHA256SUMS", data.encode("ascii"), registry)


def build_pack(
    pack_root: Path,
    artifact_root: Path,
    run_prefixes: dict[str, Path],
    summary_provider: SummaryProvider = xcresult_summary,
) -> None:
    schema = load_schema()
    require(tuple(run_prefixes) == schema.run_ids, "run prefixes must follow the six schema IDs")
    require(
        pack_root != artifact_root
        and pack_root not in artifact_root.parents
        and artifact_root not in pack_root.parents,
        "pack and artifact roots must be separate",
    )
    runs = [load_run_input(run_id, run_prefixes[run_id], schema) for run_id in schema.run_ids]
    pack_identity = create_fresh_root(pack_root, "pack root")
    artifact_identity: tuple[int, int] | None = None
    try:
        artifact_identity = create_fresh_root(artifact_root, "artifact root")
        pack_registry = DestinationRegistry(pack_root)
        artifact_store = ArtifactStore(artifact_root)
        tooling = _copy_tooling(pack_root, pack_registry, schema)
        run_records = [
            _copy_run(run, pack_root, pack_registry, artifact_store, schema, summary_provider)
            for run in runs
        ]
        retained_reference = pack_root / "reference"
        manifest = {
            "format": CURRENT_MANIFEST_FORMAT,
            "gate": "editor-find-f2-retained-evidence",
            "schemaSHA256": schema.digest,
            "sourceCommit": schema.source_commit,
            "tooling": {
                "files": tooling,
                "captureSHA256": tooling_digest(retained_reference, schema.capture_tooling_paths),
                "auditorSHA256": tooling_digest(
                    retained_reference,
                    auditor_paths_for_manifest(schema, CURRENT_MANIFEST_FORMAT),
                ),
            },
            "runs": run_records,
            "boundaries": {
                "fullKeystrokeToScreen": "open",
                "f8HighlightApplyClear": "open",
                "f9": "open",
                "combinedTip": "open",
            },
        }
        write_exclusive(pack_root / "manifest.json", _json_bytes(manifest), pack_registry)
        _write_inventory(pack_root, pack_registry)
        validate_pack(pack_root, None)
        validate_pack(pack_root, artifact_root)
    except Exception:
        if artifact_identity is not None:
            remove_fresh_root(artifact_root, artifact_identity)
        remove_fresh_root(pack_root, pack_identity)
        raise
