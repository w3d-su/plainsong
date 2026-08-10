set -euo pipefail

if [[ "$#" -ne 4 ]]; then
    echo "usage: $0 CONFIGURATION DERIVED_DATA_PATH RESULT_BUNDLE_PATH LOG_PATH" >&2
    exit 2
fi

configuration="$1"
derived_data_path="$2"
result_bundle_path="$3"
log_path="$4"

if [[ "$derived_data_path" != /* || "$derived_data_path" == *[[:space:]]* ||
    ! "${derived_data_path##*/}" =~ ^[A-Za-z0-9._-]+$ ||
    ! -d "$derived_data_path" || -L "$derived_data_path" ||
    "$(builtin cd "$derived_data_path" && /bin/pwd -P)" != "$derived_data_path" ]]; then
    echo "F2 DerivedData must be an absolute real canonical directory" >&2
    exit 2
fi
derived_data_owner="$(/usr/bin/stat -f '%u' "$derived_data_path")"
derived_data_mode="$(/usr/bin/stat -f '%Lp' "$derived_data_path")"
if [[ "$derived_data_owner" != "$(/usr/bin/id -u)" ||
    "$((8#$derived_data_mode & 8#022))" != "0" ]] ||
    ! f2_reject_acl_allows "$derived_data_path" ||
    ! f2_reject_tree_acls "$derived_data_path"; then
    echo "F2 DerivedData must be owner-controlled" >&2
    exit 2
fi

if [[ "$result_bundle_path" != /* || "$log_path" != /* ||
    "$result_bundle_path" == *[[:space:]]* || "$log_path" == *[[:space:]]* ||
    ! "${result_bundle_path##*/}" =~ ^[A-Za-z0-9._-]+[.]xcresult$ ||
    ! "${log_path##*/}" =~ ^[A-Za-z0-9._-]+[.]log$ ||
    "${result_bundle_path%.xcresult}" != "${log_path%.log}" ]]; then
    echo "F2 result and log must use one absolute simple output prefix" >&2
    exit 2
fi
output_prefix="${log_path%.log}"
output_parent="$(/usr/bin/dirname "$output_prefix")"
if [[ ! -d "$output_parent" || -L "$output_parent" ||
    "$(builtin cd "$output_parent" && /bin/pwd -P)" != "$output_parent" ]]; then
    echo "F2 output parent must be a real canonical directory" >&2
    exit 2
fi
output_parent_owner="$(/usr/bin/stat -f '%u' "$output_parent")"
output_parent_mode="$(/usr/bin/stat -f '%Lp' "$output_parent")"
if [[ "$output_parent_owner" != "$(/usr/bin/id -u)" ||
    "$((8#$output_parent_mode & 8#022))" != "0" ]] ||
    ! f2_reject_acl_allows "$output_parent"; then
    echo "F2 output parent must be owner-controlled" >&2
    exit 2
fi
if [[ "$output_prefix" == "$derived_data_path" ||
    "$output_prefix" == "$derived_data_path/"* ]]; then
    echo "F2 output prefix must be disjoint from DerivedData" >&2
    exit 2
fi
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
f2_output_paths=(
    "$result_bundle_path"
    "$log_path"
    "$log_digest_path"
    "$warning_check_path"
    "$warning_check_digest_path"
    "$evidence_manifest_path"
    "$snapshot_root"
    "$inspection_result_bundle_path"
)
for f2_output_path in "${f2_output_paths[@]}"; do
    if [[ -e "$f2_output_path" || -L "$f2_output_path" ]]; then
        echo "refusing to mix or overwrite existing F2 evidence artifacts" >&2
        echo "existing path: $f2_output_path" >&2
        exit 2
    fi
done

script_directory="$f2_script_directory"
repository_root="$(builtin cd "$script_directory/.." && /bin/pwd -P)"
if [[ "$derived_data_path" == "$repository_root" ||
    "$derived_data_path" == "$repository_root/"* ||
    "$repository_root" == "$derived_data_path/"* ]]; then
    echo "F2 repository and DerivedData roots must be disjoint" >&2
    exit 2
fi
bootstrap_artifact_hasher="$script_directory/hash-editor-find-f2-artifact.py"

trusted_git() {
    /usr/bin/env -i \
        GIT_CONFIG_GLOBAL=/dev/null \
        GIT_CONFIG_NOSYSTEM=1 \
        GIT_NO_REPLACE_OBJECTS=1 \
        LANG=C \
        LC_ALL=C \
        PATH=/usr/bin:/bin \
        /usr/bin/git --no-replace-objects "$@"
}

manifest_path="$derived_data_path/f2-editor-find-build-manifest.txt"
if [[ ! -f "$manifest_path" || -L "$manifest_path" ]]; then
    echo "missing authoritative F2 build manifest: $manifest_path" >&2
    exit 2
fi
manifest_owner="$(/usr/bin/stat -f '%u' "$manifest_path")"
if [[ "$manifest_owner" != "$(/usr/bin/id -u)" ]] ||
    ! f2_reject_acl_allows "$manifest_path"; then
    echo "authoritative F2 build manifest must be owner-controlled" >&2
    exit 2
fi
manifest_writable_entry="$(
    /usr/bin/find "$manifest_path" -perm +0222 -print -quit
)"
if [[ -n "$manifest_writable_entry" ]]; then
    echo "authoritative F2 build manifest is not read-only: $manifest_path" >&2
    exit 2
fi
manifest_sha256="$(f2_sha256_file "$manifest_path")"

worktree_status="$(
    trusted_git -C "$repository_root" status --porcelain=v1 --untracked-files=all
)"
if [[ -n "$worktree_status" ]]; then
    echo "authoritative F2 runs require a clean worktree:" >&2
    echo "$worktree_status" >&2
    exit 2
fi
source_commit="$(trusted_git -C "$repository_root" rev-parse HEAD)"

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
manifest_resolved_package_input_sha256=""
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
        resolved_package_input_sha256)
            manifest_resolved_package_input_sha256="$value"
            ;;
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

if [[ "$manifest_format" != "5" ]]; then
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
for exact_input_directory in \
    "$manifest_source_snapshot_path" \
    "$manifest_package_input_path"; do
    if [[ ! -d "$exact_input_directory" || -L "$exact_input_directory" ||
        "$(builtin cd "$exact_input_directory" && /bin/pwd -P)" != \
            "$exact_input_directory" ||
        "$(/usr/bin/stat -f '%u' "$exact_input_directory")" != \
            "$(/usr/bin/id -u)" ]]; then
        echo "F2 manifest input is not a canonical owner-controlled directory" >&2
        echo "input: $exact_input_directory" >&2
        exit 2
    fi
done
if [[ ! -f "$manifest_source_archive_path" ||
    -L "$manifest_source_archive_path" ||
    "$(/usr/bin/stat -f '%u' "$manifest_source_archive_path")" != \
        "$(/usr/bin/id -u)" ]]; then
    echo "F2 source archive is not a regular owner-controlled file" >&2
    exit 2
fi
for protected_root in \
    "$repository_root" \
    "$manifest_source_snapshot_path" \
    "$manifest_package_input_path"; do
    if [[ "$output_prefix" == "$protected_root" ||
        "$output_prefix" == "$protected_root/"* ]]; then
        echo "F2 output prefix overlaps a protected source/build root" >&2
        echo "protected: $protected_root" >&2
        exit 2
    fi
done
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
