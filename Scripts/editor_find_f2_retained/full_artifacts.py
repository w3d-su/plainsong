from __future__ import annotations

from .artifacts import (
    path_identity,
    reject_tree_symlinks,
    require_artifact_entry_type,
    require_owner_controlled_directory,
    require_read_only_tree,
)
from .context import FULL_ARTIFACT_NAMES, FULL_ARTIFACT_TYPES, Path, tempfile
from .core import require
from .trusted import (
    copy_artifact_snapshot,
    hash_full_artifact,
    inspect_full_xcresult,
    resolve_artifact_path,
    verify_source_archive_commit,
)

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

    for index, item in enumerate(
        (item for _, item in sorted(original_records.items())),
        start=1,
    ):
        with tempfile.TemporaryDirectory(
            prefix=f"plainsong-f2-full-artifact-{index}.",
            dir="/private/tmp",
        ) as temporary:
            snapshot = Path(temporary) / "artifact"
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

    verified_source_pairs: set[tuple[str, str]] = set()
    for record in run_records:
        run_id = record["id"]
        prepared = run_artifacts[run_id]
        source_pair = (
            str(prepared["sourceArchive"]["path"]),
            str(prepared["sourceSnapshot"]["path"]),
        )
        if source_pair not in verified_source_pairs:
            with tempfile.TemporaryDirectory(
                prefix="plainsong-f2-source-pair-audit.",
                dir="/private/tmp",
            ) as temporary:
                private_root = Path(temporary)
                archive = private_root / "source.tar"
                source_snapshot = private_root / "source"
                for name, destination in (
                    ("sourceArchive", archive),
                    ("sourceSnapshot", source_snapshot),
                ):
                    item = prepared[name]
                    copy_artifact_snapshot(
                        item["path"],
                        destination,
                        item["type"],
                        item["hashMode"],
                    )
                    require(
                        hash_full_artifact(destination, item["hashMode"])
                        == item["sha256"],
                        f"{run_id}: private {name} snapshot differs",
                    )
                verify_source_archive_commit(
                    archive,
                    source_snapshot,
                    prepared["sourceArchive"]["sha256"],
                    record["build"]["source_tree_sha256"],
                )
            verified_source_pairs.add(source_pair)
        inspect_full_xcresult(
            prepared["xcresult"]["path"],
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
