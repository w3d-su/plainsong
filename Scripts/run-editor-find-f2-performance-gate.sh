#!/bin/bash

set -euo pipefail

if [[ "$#" -ne 4 ]]; then
    echo "usage: $0 CONFIGURATION DERIVED_DATA_PATH RESULT_BUNDLE_PATH LOG_PATH" >&2
    exit 2
fi

configuration="$1"
derived_data_path="$2"
result_bundle_path="$3"
log_path="$4"
warning_check_path="${log_path%.log}.warning-check.txt"
log_digest_path="${log_path}.sha256"
warning_check_digest_path="${warning_check_path}.sha256"
evidence_manifest_path="${log_path%.log}.evidence-manifest.txt"
snapshot_root="${result_bundle_path%.xcresult}.products"
inspection_result_bundle_path="${result_bundle_path%.xcresult}.inspection.xcresult"

if [[ "$configuration" != "Debug" && "$configuration" != "Release" ]]; then
    echo "configuration must be Debug or Release, got: $configuration" >&2
    exit 2
fi
if [[ "${CI:-}" == "true" || "${GITHUB_ACTIONS:-}" == "true" ||
    "${TEST_RUNNER_CI:-}" == "true" ||
    "${TEST_RUNNER_GITHUB_ACTIONS:-}" == "true" ]]; then
    echo "authoritative F2 runs are local-only and reject CI budget mode" >&2
    exit 2
fi
if [[ -e "$result_bundle_path" || -e "$log_path" ||
    -e "$log_digest_path" || -e "$warning_check_path" ||
    -e "$warning_check_digest_path" || -e "$evidence_manifest_path" ||
    -e "$snapshot_root" || -e "$inspection_result_bundle_path" ]]; then
    echo "refusing to mix or overwrite existing F2 evidence artifacts" >&2
    echo "result: $result_bundle_path" >&2
    echo "log: $log_path" >&2
    echo "log digest: $log_digest_path" >&2
    echo "check: $warning_check_path" >&2
    echo "check digest: $warning_check_digest_path" >&2
    echo "evidence manifest: $evidence_manifest_path" >&2
    echo "snapshot: $snapshot_root" >&2
    echo "xcresult inspection copy: $inspection_result_bundle_path" >&2
    exit 2
fi

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_directory/.." && pwd)"
bootstrap_artifact_hasher="$script_directory/hash-editor-find-f2-artifact.py"
manifest_path="$derived_data_path/f2-editor-find-build-manifest.txt"
if [[ ! -f "$manifest_path" ]]; then
    echo "missing authoritative F2 build manifest: $manifest_path" >&2
    exit 2
fi
manifest_writable_entry="$(
    /usr/bin/find "$manifest_path" -perm +0222 -print -quit
)"
if [[ -n "$manifest_writable_entry" ]]; then
    echo "authoritative F2 build manifest is not read-only: $manifest_path" >&2
    exit 2
fi
manifest_sha256="$(
    /usr/bin/shasum -a 256 "$manifest_path" |
        /usr/bin/awk '{print $1}'
)"

worktree_status="$(
    /usr/bin/git -C "$repository_root" status --porcelain=v1 --untracked-files=all
)"
if [[ -n "$worktree_status" ]]; then
    echo "authoritative F2 runs require a clean worktree:" >&2
    echo "$worktree_status" >&2
    exit 2
fi
source_commit="$(/usr/bin/git -C "$repository_root" rev-parse HEAD)"

manifest_format=""
manifest_source_commit=""
manifest_configuration=""
manifest_repository_root=""
manifest_source_snapshot_path=""
manifest_source_archive_path=""
manifest_source_archive_sha256=""
manifest_source_tree_sha256=""
manifest_build_input_sha256=""
manifest_package_input_path=""
manifest_package_input_sha256=""
manifest_xcodegen_path=""
manifest_xcodegen_sha256=""
manifest_destination=""
manifest_budget_mode=""
manifest_host_bundle_sha256=""
manifest_xctestrun_relative_path=""
manifest_xctestrun_sha256=""
while IFS="=" read -r key value; do
    case "$key" in
        format) manifest_format="$value" ;;
        source_commit) manifest_source_commit="$value" ;;
        configuration) manifest_configuration="$value" ;;
        repository_root) manifest_repository_root="$value" ;;
        source_snapshot_path) manifest_source_snapshot_path="$value" ;;
        source_archive_path) manifest_source_archive_path="$value" ;;
        source_archive_sha256) manifest_source_archive_sha256="$value" ;;
        source_tree_sha256) manifest_source_tree_sha256="$value" ;;
        build_input_sha256) manifest_build_input_sha256="$value" ;;
        package_input_path) manifest_package_input_path="$value" ;;
        package_input_sha256) manifest_package_input_sha256="$value" ;;
        xcodegen_path) manifest_xcodegen_path="$value" ;;
        xcodegen_sha256) manifest_xcodegen_sha256="$value" ;;
        destination) manifest_destination="$value" ;;
        budget_mode) manifest_budget_mode="$value" ;;
        host_bundle_sha256) manifest_host_bundle_sha256="$value" ;;
        xctestrun_relative_path) manifest_xctestrun_relative_path="$value" ;;
        xctestrun_sha256) manifest_xctestrun_sha256="$value" ;;
        *)
            echo "unexpected F2 build manifest key: $key" >&2
            exit 2
            ;;
    esac
done < "$manifest_path"

if [[ "$manifest_format" != "4" ]]; then
    echo "unsupported F2 build manifest format: $manifest_format" >&2
    exit 2
fi
if [[ "$manifest_source_commit" != "$source_commit" ]]; then
    echo "F2 build/source mismatch" >&2
    echo "manifest: $manifest_source_commit" >&2
    echo "current: $source_commit" >&2
    exit 2
fi
if [[ "$manifest_configuration" != "$configuration" ]]; then
    echo "F2 build configuration mismatch" >&2
    echo "manifest: $manifest_configuration" >&2
    echo "requested: $configuration" >&2
    exit 2
fi
if [[ "$manifest_repository_root" != "$repository_root" ]]; then
    echo "F2 build repository mismatch" >&2
    echo "manifest: $manifest_repository_root" >&2
    echo "current: $repository_root" >&2
    exit 2
fi
expected_source_snapshot_path="${derived_data_path}.source"
expected_source_archive_path="${derived_data_path}.source.tar"
expected_package_input_path="$derived_data_path/SourcePackages"
if [[ "$manifest_source_snapshot_path" != "$expected_source_snapshot_path" ||
    "$manifest_source_archive_path" != "$expected_source_archive_path" ||
    "$manifest_package_input_path" != "$expected_package_input_path" ]]; then
    echo "F2 exact-source artifact paths do not match DerivedData" >&2
    echo "snapshot: $manifest_source_snapshot_path" >&2
    echo "archive: $manifest_source_archive_path" >&2
    echo "package input: $manifest_package_input_path" >&2
    exit 2
fi
current_host_architecture="$(/usr/bin/uname -m)"
expected_destination="platform=macOS,arch=$current_host_architecture"
if [[ "$manifest_destination" != "$expected_destination" ]]; then
    echo "F2 build destination does not match the current host" >&2
    echo "manifest: $manifest_destination" >&2
    echo "current: $expected_destination" >&2
    exit 2
fi
if [[ "$manifest_budget_mode" != "local-hard" ]]; then
    echo "F2 build manifest is not in hard-local budget mode" >&2
    echo "manifest: $manifest_budget_mode" >&2
    exit 2
fi

checker="$manifest_source_snapshot_path/Scripts/check-editor-find-f2-warning-phase.py"
artifact_hasher="$manifest_source_snapshot_path/Scripts/hash-editor-find-f2-artifact.py"
stream_capturer="$manifest_source_snapshot_path/Scripts/capture-editor-find-f2-log.py"

verify_build_source_snapshot() {
    local build_input_sha256
    local source_archive_sha256
    local source_archive_writable_entry
    local writable_entry

    if [[ ! -d "$manifest_source_snapshot_path" ||
        ! -f "$manifest_source_archive_path" ||
        ! -f "$checker" || ! -f "$artifact_hasher" ||
        ! -f "$stream_capturer" ]]; then
        echo "F2 exact-source build artifacts are incomplete" >&2
        return 1
    fi
    if ! writable_entry="$(
        /usr/bin/find "$manifest_source_snapshot_path" \
            -perm +0222 -print -quit
    )"; then
        echo "could not verify F2 exact-source snapshot permissions" >&2
        return 1
    fi
    if [[ -n "$writable_entry" ]]; then
        echo "F2 exact-source snapshot is not read-only: $writable_entry" >&2
        return 1
    fi
    if ! source_archive_writable_entry="$(
        /usr/bin/find "$manifest_source_archive_path" \
            -perm +0222 -print -quit
    )"; then
        echo "could not verify F2 source-archive permissions" >&2
        return 1
    fi
    if [[ -n "$source_archive_writable_entry" ]]; then
        echo "F2 source archive is not read-only: $source_archive_writable_entry" >&2
        return 1
    fi
    if ! source_archive_sha256="$(
        /usr/bin/shasum -a 256 "$manifest_source_archive_path" |
            /usr/bin/awk '{print $1}'
    )"; then
        echo "could not hash the F2 source archive" >&2
        return 1
    fi
    if ! build_input_sha256="$(
        /usr/bin/python3 "$bootstrap_artifact_hasher" \
            "$manifest_source_snapshot_path"
    )"; then
        echo "could not hash the F2 exact-source build input" >&2
        return 1
    fi
    if [[ "$source_archive_sha256" != "$manifest_source_archive_sha256" ]]; then
        echo "F2 source archive differs from the build manifest" >&2
        return 1
    fi
    if [[ "$build_input_sha256" != "$manifest_build_input_sha256" ]]; then
        echo "F2 exact-source build input differs from the build manifest" >&2
        return 1
    fi
}

verify_package_input() {
    local package_input_sha256
    local writable_entry

    if [[ ! -d "$manifest_package_input_path/checkouts" ]]; then
        echo "F2 resolved SwiftPM package input is incomplete" >&2
        return 1
    fi
    if ! writable_entry="$(
        /usr/bin/find "$manifest_package_input_path" \
            -perm +0222 -print -quit
    )"; then
        echo "could not verify F2 package-input permissions" >&2
        return 1
    fi
    if [[ -n "$writable_entry" ]]; then
        echo "F2 package input is not read-only: $writable_entry" >&2
        return 1
    fi
    if ! package_input_sha256="$(
        /usr/bin/python3 "$artifact_hasher" "$manifest_package_input_path"
    )"; then
        echo "could not hash the F2 package input" >&2
        return 1
    fi
    if [[ "$package_input_sha256" != "$manifest_package_input_sha256" ]]; then
        echo "F2 package input differs from the build manifest" >&2
        return 1
    fi
}

products_directory="$derived_data_path/Build/Products/$configuration"
host_bundle="$products_directory/Plainsong.app"
performance_test_bundle="$host_bundle/Contents/PlugIns/PerformanceTests.xctest"
if [[ "$manifest_xctestrun_relative_path" != Build/Products/*.xctestrun ||
    "$manifest_xctestrun_relative_path" == *".."* ]]; then
    echo "invalid F2 .xctestrun manifest path: $manifest_xctestrun_relative_path" >&2
    exit 2
fi
xctestrun_path="$derived_data_path/$manifest_xctestrun_relative_path"

verify_build_product_hashes() {
    local host_bundle_sha256
    local xctestrun_sha256

    if [[ ! -d "$host_bundle" || ! -d "$performance_test_bundle" ||
        ! -f "$xctestrun_path" ]]; then
        echo "F2 host, PerformanceTests, or .xctestrun artifact is missing" >&2
        return 1
    fi
    if ! host_bundle_sha256="$(
        /usr/bin/python3 "$artifact_hasher" "$host_bundle"
    )"; then
        echo "could not hash the F2 host bundle" >&2
        return 1
    fi
    if ! xctestrun_sha256="$(
        /usr/bin/python3 "$artifact_hasher" "$xctestrun_path"
    )"; then
        echo "could not hash the F2 .xctestrun" >&2
        return 1
    fi
    if [[ "$host_bundle_sha256" != "$manifest_host_bundle_sha256" ]]; then
        echo "F2 host bundle differs from the build manifest" >&2
        return 1
    fi
    if [[ "$xctestrun_sha256" != "$manifest_xctestrun_sha256" ]]; then
        echo "F2 .xctestrun differs from the build manifest" >&2
        return 1
    fi
}

snapshot_host_bundle="$snapshot_root/Build/Products/$configuration/Plainsong.app"
snapshot_xctestrun_path="$snapshot_root/$manifest_xctestrun_relative_path"

verify_snapshot_hashes() {
    local host_bundle_sha256
    local xctestrun_sha256
    local writable_entry

    if [[ ! -d "$snapshot_host_bundle" ||
        ! -d "$snapshot_host_bundle/Contents/PlugIns/PerformanceTests.xctest" ||
        ! -f "$snapshot_xctestrun_path" ]]; then
        echo "F2 per-run product snapshot is incomplete" >&2
        return 1
    fi
    if ! writable_entry="$(
        /usr/bin/find "$snapshot_root" -perm +0222 -print -quit
    )"; then
        echo "could not verify F2 snapshot permissions" >&2
        return 1
    fi
    if [[ -n "$writable_entry" ]]; then
        echo "F2 per-run product snapshot is not read-only: $writable_entry" >&2
        return 1
    fi
    if ! host_bundle_sha256="$(
        /usr/bin/python3 "$artifact_hasher" "$snapshot_host_bundle"
    )"; then
        echo "could not hash the F2 snapshot host bundle" >&2
        return 1
    fi
    if ! xctestrun_sha256="$(
        /usr/bin/python3 "$artifact_hasher" "$snapshot_xctestrun_path"
    )"; then
        echo "could not hash the F2 snapshot .xctestrun" >&2
        return 1
    fi
    if [[ "$host_bundle_sha256" != "$manifest_host_bundle_sha256" ]]; then
        echo "F2 snapshot host bundle differs from the build manifest" >&2
        return 1
    fi
    if [[ "$xctestrun_sha256" != "$manifest_xctestrun_sha256" ]]; then
        echo "F2 snapshot .xctestrun differs from the build manifest" >&2
        return 1
    fi
}

verify_source_checkout() {
    local current_commit
    local current_status

    if ! current_status="$(
        /usr/bin/git -C "$repository_root" \
            status --porcelain=v1 --untracked-files=all
    )"; then
        echo "could not inspect the F2 source checkout status" >&2
        return 1
    fi
    if ! current_commit="$(
        /usr/bin/git -C "$repository_root" rev-parse HEAD
    )"; then
        echo "could not inspect the F2 source checkout HEAD" >&2
        return 1
    fi
    if [[ -n "$current_status" ]]; then
        echo "source checkout became dirty during the F2 run:" >&2
        echo "$current_status" >&2
        return 1
    fi
    if [[ "$current_commit" != "$manifest_source_commit" ]]; then
        echo "source HEAD changed during the F2 run" >&2
        echo "manifest: $manifest_source_commit" >&2
        echo "current: $current_commit" >&2
        return 1
    fi
}

verify_build_manifest() {
    local current_sha256
    local writable_entry

    if [[ ! -f "$manifest_path" ]]; then
        echo "F2 build manifest disappeared during the run" >&2
        return 1
    fi
    if ! writable_entry="$(
        /usr/bin/find "$manifest_path" -perm +0222 -print -quit
    )"; then
        echo "could not verify F2 build-manifest permissions" >&2
        return 1
    fi
    if [[ -n "$writable_entry" ]]; then
        echo "F2 build manifest is not read-only: $writable_entry" >&2
        return 1
    fi
    if ! current_sha256="$(
        /usr/bin/shasum -a 256 "$manifest_path" |
            /usr/bin/awk '{print $1}'
    )"; then
        echo "could not hash the F2 build manifest" >&2
        return 1
    fi
    if [[ "$current_sha256" != "$manifest_sha256" ]]; then
        echo "F2 build manifest changed after it was parsed" >&2
        return 1
    fi
}

verify_static_integrity() {
    verify_source_checkout || return 1
    verify_build_manifest || return 1
    verify_build_source_snapshot || return 1
    verify_package_input || return 1
    verify_build_product_hashes || return 1
    verify_snapshot_hashes || return 1
}

verify_build_source_snapshot
verify_package_input
verify_build_product_hashes
/bin/mkdir -p "$snapshot_root/Build/Products/$configuration"
/usr/bin/ditto "$host_bundle" "$snapshot_host_bundle"
/usr/bin/ditto "$xctestrun_path" "$snapshot_xctestrun_path"
/bin/chmod -R a-w "$snapshot_root"
verify_snapshot_hashes

arguments=(
    -xctestrun "$snapshot_xctestrun_path"
    -destination "$manifest_destination"
    -resultBundlePath "$result_bundle_path"
    -only-testing:PerformanceTests/EditorFindPerformanceTests
    test-without-building
)

set +e
CI=false GITHUB_ACTIONS=false \
    TEST_RUNNER_CI=false TEST_RUNNER_GITHUB_ACTIONS=false \
    /usr/bin/xcodebuild "${arguments[@]}" 2>&1 |
    /usr/bin/python3 "$stream_capturer" "$log_path" "$log_digest_path"
xcode_pipeline_statuses=("${PIPESTATUS[@]}")
set -e
xcodebuild_status="${xcode_pipeline_statuses[0]}"
log_capture_status="${xcode_pipeline_statuses[1]}"

if [[ "$log_capture_status" -ne 0 ]]; then
    echo "F2 authoritative run failed: raw-log capture exited $log_capture_status" >&2
    exit "$log_capture_status"
fi
if [[ "$xcodebuild_status" -ne 0 ]]; then
    echo "F2 authoritative run failed: xcodebuild exited $xcodebuild_status" >&2
    exit "$xcodebuild_status"
fi

parsed_capture_sha256=""
parsed_capture_bytes=""
parse_capture_record() {
    local digest_line
    local byte_line
    local extra_line=""

    if [[ ! -f "$1" ]]; then
        echo "missing F2 streaming digest record: $1" >&2
        return 1
    fi
    if ! exec 9< "$1"; then
        echo "could not open F2 streaming digest record: $1" >&2
        return 1
    fi
    if ! IFS= read -r digest_line <&9 ||
        ! IFS= read -r byte_line <&9; then
        exec 9<&-
        echo "incomplete F2 streaming digest record: $1" >&2
        return 1
    fi
    if IFS= read -r extra_line <&9 || [[ -n "$extra_line" ]]; then
        exec 9<&-
        echo "unexpected extra F2 streaming digest fields: $1" >&2
        return 1
    fi
    exec 9<&-
    parsed_capture_sha256="${digest_line#sha256=}"
    parsed_capture_bytes="${byte_line#bytes=}"
    if [[ "$digest_line" != "sha256=$parsed_capture_sha256" ||
        ! "$parsed_capture_sha256" =~ ^[0-9a-f]{64}$ ||
        "$byte_line" != "bytes=$parsed_capture_bytes" ||
        ! "$parsed_capture_bytes" =~ ^[0-9]+$ ]]; then
        echo "invalid F2 streaming digest record: $1" >&2
        return 1
    fi
}

verify_stream_capture() {
    local output_path="$1"
    local digest_path="$2"
    local expected_sha256="$3"
    local expected_bytes="$4"
    local actual_sha256
    local actual_bytes
    local writable_entry

    if [[ ! -f "$output_path" || ! -f "$digest_path" ]]; then
        echo "F2 streaming capture is incomplete: $output_path" >&2
        return 1
    fi
    if ! writable_entry="$(
        /usr/bin/find "$output_path" "$digest_path" \
            -perm +0222 -print -quit
    )"; then
        echo "could not verify F2 streaming-capture permissions" >&2
        return 1
    fi
    if [[ -n "$writable_entry" ]]; then
        echo "F2 streaming capture is not read-only: $writable_entry" >&2
        return 1
    fi
    if ! parse_capture_record "$digest_path"; then
        return 1
    fi
    if [[ "$parsed_capture_sha256" != "$expected_sha256" ||
        "$parsed_capture_bytes" != "$expected_bytes" ]]; then
        echo "F2 streaming digest record changed: $digest_path" >&2
        return 1
    fi
    if ! actual_sha256="$(
        /usr/bin/shasum -a 256 "$output_path" |
            /usr/bin/awk '{print $1}'
    )"; then
        echo "could not hash F2 streaming capture: $output_path" >&2
        return 1
    fi
    if ! actual_bytes="$(/usr/bin/stat -f %z "$output_path")"; then
        echo "could not size F2 streaming capture: $output_path" >&2
        return 1
    fi
    if [[ "$actual_sha256" != "$expected_sha256" ||
        "$actual_bytes" != "$expected_bytes" ]]; then
        echo "F2 streaming capture differs from its bound digest: $output_path" >&2
        return 1
    fi
}

if ! parse_capture_record "$log_digest_path"; then
    exit 1
fi
captured_log_sha256="$parsed_capture_sha256"
captured_log_bytes="$parsed_capture_bytes"
if ! verify_stream_capture \
    "$log_path" "$log_digest_path" \
    "$captured_log_sha256" "$captured_log_bytes"; then
    exit 1
fi

if [[ ! -d "$result_bundle_path" ]]; then
    echo "F2 authoritative run did not produce an xcresult bundle" >&2
    exit 1
fi
/bin/chmod -R a-w "$result_bundle_path"
result_writable_entry="$(
    /usr/bin/find "$result_bundle_path" -perm +0222 -print -quit
)"
if [[ -n "$result_writable_entry" ]]; then
    echo "F2 xcresult bundle is not read-only: $result_writable_entry" >&2
    exit 1
fi
result_bundle_sha256="$(
    /usr/bin/python3 "$artifact_hasher" "$result_bundle_path"
)"
/usr/bin/ditto --noextattr --noqtn --noacl \
    "$result_bundle_path" "$inspection_result_bundle_path"
/bin/chmod -R u+w "$inspection_result_bundle_path"
inspection_input_sha256="$(
    /usr/bin/python3 "$artifact_hasher" "$inspection_result_bundle_path"
)"
if [[ "$inspection_input_sha256" != "$result_bundle_sha256" ]]; then
    echo "F2 xcresult inspection copy differs from the sealed raw result" >&2
    exit 1
fi

verify_run_evidence_inputs() {
    local current_result_sha256
    local writable_entry

    verify_stream_capture \
        "$log_path" "$log_digest_path" \
        "$captured_log_sha256" "$captured_log_bytes" || return 1
    if ! writable_entry="$(
        /usr/bin/find "$result_bundle_path" -perm +0222 -print -quit
    )"; then
        echo "could not verify F2 xcresult permissions" >&2
        return 1
    fi
    if [[ -n "$writable_entry" ]]; then
        echo "F2 xcresult bundle is not read-only: $writable_entry" >&2
        return 1
    fi
    if ! current_result_sha256="$(
        /usr/bin/python3 "$artifact_hasher" "$result_bundle_path"
    )"; then
        echo "could not hash the F2 xcresult bundle" >&2
        return 1
    fi
    if [[ "$current_result_sha256" != "$result_bundle_sha256" ]]; then
        echo "F2 xcresult bundle changed after capture" >&2
        return 1
    fi
}

verify_inspection_input() {
    local current_sha256

    if [[ ! -d "$inspection_result_bundle_path" ]]; then
        echo "F2 xcresult inspection input is missing" >&2
        return 1
    fi
    if ! current_sha256="$(
        /usr/bin/python3 "$artifact_hasher" "$inspection_result_bundle_path"
    )"; then
        echo "could not hash the F2 xcresult inspection input" >&2
        return 1
    fi
    if [[ "$current_sha256" != "$result_bundle_sha256" ]]; then
        echo "F2 xcresult inspection input changed before validation" >&2
        return 1
    fi
}

if ! verify_run_evidence_inputs ||
    ! verify_inspection_input ||
    ! verify_static_integrity; then
    echo "F2 authoritative run failed: post-run inputs failed integrity checks" >&2
    exit 1
fi

source_check_line="F2 SOURCE CHECK PASS commit=$source_commit configuration=$configuration budget-mode=$manifest_budget_mode build-manifest-readonly=true build-manifest-sha256=$manifest_sha256 exact-source-readonly=true build-input-sha256=$manifest_build_input_sha256 package-input-readonly=true package-input-sha256=$manifest_package_input_sha256 snapshot-readonly=true frozen-products=$snapshot_root host-bundle-sha256=$manifest_host_bundle_sha256 xctestrun-sha256=$manifest_xctestrun_sha256 raw-log-readonly=true raw-log-sha256=$captured_log_sha256 xcresult-readonly=true xcresult-sha256=$result_bundle_sha256 xcresult-inspection-input-sha256=$inspection_input_sha256"

set +e
{
    echo "$source_check_line"
    /usr/bin/python3 "$checker" \
        "$log_path" "$inspection_result_bundle_path" \
        "$captured_log_sha256" "$result_bundle_sha256"
} 2>&1 |
    /usr/bin/python3 "$stream_capturer" \
        "$warning_check_path" "$warning_check_digest_path"
checker_pipeline_statuses=("${PIPESTATUS[@]}")
set -e
checker_status="${checker_pipeline_statuses[0]}"
check_capture_status="${checker_pipeline_statuses[1]}"

/bin/chmod -R a-w "$inspection_result_bundle_path"
inspection_writable_entry="$(
    /usr/bin/find "$inspection_result_bundle_path" \
        -perm +0222 -print -quit
)"
if [[ -n "$inspection_writable_entry" ]]; then
    echo "F2 xcresult inspection result is not read-only: $inspection_writable_entry" >&2
    exit 1
fi
inspection_result_sha256="$(
    /usr/bin/python3 "$artifact_hasher" "$inspection_result_bundle_path"
)"

if [[ "$check_capture_status" -ne 0 ]]; then
    echo "F2 authoritative run failed: check-output capture exited $check_capture_status" >&2
    exit "$check_capture_status"
fi
if [[ "$checker_status" -ne 0 ]]; then
    echo "F2 authoritative run failed: warning-phase check exited $checker_status" >&2
    exit "$checker_status"
fi
if ! parse_capture_record "$warning_check_digest_path"; then
    exit 1
fi
warning_check_sha256="$parsed_capture_sha256"
warning_check_bytes="$parsed_capture_bytes"
if ! verify_stream_capture \
    "$warning_check_path" "$warning_check_digest_path" \
    "$warning_check_sha256" "$warning_check_bytes"; then
    exit 1
fi

verify_inspection_result() {
    local current_sha256
    local writable_entry

    if [[ ! -d "$inspection_result_bundle_path" ]]; then
        echo "F2 xcresult inspection result is missing" >&2
        return 1
    fi
    if ! writable_entry="$(
        /usr/bin/find "$inspection_result_bundle_path" \
            -perm +0222 -print -quit
    )"; then
        echo "could not verify F2 xcresult inspection-result permissions" >&2
        return 1
    fi
    if [[ -n "$writable_entry" ]]; then
        echo "F2 xcresult inspection result is not read-only: $writable_entry" >&2
        return 1
    fi
    if ! current_sha256="$(
        /usr/bin/python3 "$artifact_hasher" "$inspection_result_bundle_path"
    )"; then
        echo "could not hash the F2 xcresult inspection result" >&2
        return 1
    fi
    if [[ "$current_sha256" != "$inspection_result_sha256" ]]; then
        echo "F2 xcresult inspection result changed after validation" >&2
        return 1
    fi
}

verify_complete_evidence() {
    verify_static_integrity || return 1
    verify_run_evidence_inputs || return 1
    verify_inspection_result || return 1
    verify_stream_capture \
        "$warning_check_path" "$warning_check_digest_path" \
        "$warning_check_sha256" "$warning_check_bytes" || return 1
}

if ! verify_complete_evidence; then
    echo "F2 authoritative run failed: final evidence integrity check failed" >&2
    exit 1
fi

{
    printf 'format=1\n'
    printf 'source_commit=%s\n' "$source_commit"
    printf 'configuration=%s\n' "$configuration"
    printf 'build_manifest_path=%s\n' "$manifest_path"
    printf 'build_manifest_sha256=%s\n' "$manifest_sha256"
    printf 'raw_log_path=%s\n' "$log_path"
    printf 'raw_log_sha256=%s\n' "$captured_log_sha256"
    printf 'raw_log_bytes=%s\n' "$captured_log_bytes"
    printf 'xcresult_path=%s\n' "$result_bundle_path"
    printf 'xcresult_sha256=%s\n' "$result_bundle_sha256"
    printf 'xcresult_inspection_path=%s\n' "$inspection_result_bundle_path"
    printf 'xcresult_inspection_input_sha256=%s\n' "$inspection_input_sha256"
    printf 'xcresult_inspection_result_sha256=%s\n' "$inspection_result_sha256"
    printf 'warning_check_path=%s\n' "$warning_check_path"
    printf 'warning_check_sha256=%s\n' "$warning_check_sha256"
    printf 'warning_check_bytes=%s\n' "$warning_check_bytes"
    printf 'status=pass\n'
} > "$evidence_manifest_path"
/bin/chmod a-w "$evidence_manifest_path"
evidence_manifest_sha256="$(
    /usr/bin/shasum -a 256 "$evidence_manifest_path" |
        /usr/bin/awk '{print $1}'
)"

verify_evidence_manifest() {
    local current_sha256
    local writable_entry

    if ! writable_entry="$(
        /usr/bin/find "$evidence_manifest_path" -perm +0222 -print -quit
    )"; then
        echo "could not verify the F2 evidence-manifest permissions" >&2
        return 1
    fi
    if [[ -n "$writable_entry" ]]; then
        echo "F2 evidence manifest is not read-only: $writable_entry" >&2
        return 1
    fi
    if ! current_sha256="$(
        /usr/bin/shasum -a 256 "$evidence_manifest_path" |
            /usr/bin/awk '{print $1}'
    )"; then
        echo "could not hash the F2 evidence manifest" >&2
        return 1
    fi
    if [[ "$current_sha256" != "$evidence_manifest_sha256" ]]; then
        echo "F2 evidence manifest changed after sealing" >&2
        return 1
    fi
}

if ! verify_complete_evidence || ! verify_evidence_manifest; then
    echo "F2 authoritative run failed: last integrity check failed" >&2
    exit 1
fi

echo "F2 FINAL INTEGRITY PASS commit=$source_commit configuration=$configuration build-manifest-readonly=true build-manifest-sha256=$manifest_sha256 exact-source-readonly=true package-input-readonly=true snapshot-readonly=true raw-log-readonly=true raw-log-sha256=$captured_log_sha256 xcresult-readonly=true xcresult-sha256=$result_bundle_sha256 xcresult-inspection-readonly=true xcresult-inspection-input-sha256=$inspection_input_sha256 xcresult-inspection-result-sha256=$inspection_result_sha256 warning-check-readonly=true warning-check-sha256=$warning_check_sha256 evidence-manifest-readonly=true evidence-manifest-sha256=$evidence_manifest_sha256"
