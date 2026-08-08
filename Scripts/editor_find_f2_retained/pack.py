from __future__ import annotations

from .artifacts import path_identity, require_owner_controlled_directory
from .context import (
    BUILD_KEYS,
    EXPECTED_BUDGETS,
    EXPECTED_FIXTURE,
    EXPECTED_RUN_IDS,
    FIXTURE_BYTES,
    FIXTURE_SHA256,
    REPOSITORY_ROOT,
    RUN_FILE_NAMES,
    SOURCE_COMMIT,
    WARNING_CHECKER_SHA256,
    Path,
    contextlib,
    io,
    shutil,
    tempfile,
)
from .core import (
    load_json,
    pack_file,
    parse_key_values,
    require,
    require_keys,
    require_sha256,
    sha256_file,
    validate_inventory,
)
from .full_artifacts import verify_full_artifacts
from .logs import odd_median
from .provenance import validate_build_manifest, validate_manifest
from .run import validate_run
from .trusted import make_tree_owner_writable

def validate_pack_snapshot(pack_root: Path, artifact_root: Path | None) -> None:
    require(pack_root.is_dir() and not pack_root.is_symlink(), f"pack path is not a directory: {pack_root}")
    inventory = validate_inventory(pack_root)
    manifest_path = pack_file(pack_root, inventory, "manifest.json", "manifest")
    manifest = validate_manifest(load_json(manifest_path, "manifest.json"))

    fixture_path = REPOSITORY_ROOT / EXPECTED_FIXTURE["path"]
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
    print("F2 OPEN independent-durable-retention")
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
