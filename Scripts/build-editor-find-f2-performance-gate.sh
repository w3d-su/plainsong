#!/bin/bash -p

set -euo pipefail
builtin umask 077

if [[ "$-" != *p* ]]; then
    echo "F2 tooling entry point requires privileged Bash mode" >&2
    echo "invoke the absolute path directly or use /bin/bash -p" >&2
    exit 2
fi

if [[ "$#" -ne 2 ]]; then
    echo "usage: $0 CONFIGURATION DERIVED_DATA_PATH" >&2
    exit 2
fi

configuration="$1"
derived_data_path="$2"
source_snapshot_path="${derived_data_path}.source"
source_archive_path="${derived_data_path}.source.tar"

script_source="${BASH_SOURCE[0]}"
if [[ "$script_source" != /* || -L "$script_source" ||
    ! -f "$script_source" ]]; then
    echo "F2 build entry point must be an absolute regular non-symlink" >&2
    exit 2
fi
script_directory="$(
    builtin cd "$(/usr/bin/dirname "$script_source")" && /bin/pwd -P
)"
if [[ "$script_source" != "$script_directory/${script_source##*/}" ||
    -L "$script_directory" ]]; then
    echo "F2 build tooling directory must be canonical" >&2
    exit 2
fi

f2_reject_acl_allows() {
    local acl_listing

    if ! acl_listing="$(LC_ALL=C /bin/ls -lde "$1")"; then
        return 1
    fi
    [[ "$acl_listing" != *$'\n'*" allow "* ]]
}

f2_reject_tree_acls() {
    local acl_entry

    if ! acl_entry="$(/usr/bin/find "$1" -acl -print -quit)"; then
        return 1
    fi
    [[ -z "$acl_entry" ]]
}

script_owner="$(/usr/bin/stat -f '%u' "$script_source")"
script_mode="$(/usr/bin/stat -f '%Lp' "$script_source")"
script_directory_owner="$(/usr/bin/stat -f '%u' "$script_directory")"
script_directory_mode="$(/usr/bin/stat -f '%Lp' "$script_directory")"
if [[ "$script_owner" != "$(/usr/bin/id -u)" ||
    "$script_directory_owner" != "$(/usr/bin/id -u)" ||
    "$((8#$script_mode & 8#022))" != "0" ||
    "$((8#$script_directory_mode & 8#022))" != "0" ]] ||
    ! f2_reject_acl_allows "$script_source" ||
    ! f2_reject_acl_allows "$script_directory"; then
    echo "F2 build tooling entry point and directory must be owner-controlled" >&2
    exit 2
fi

f2_sha256_file() {
    /usr/bin/env -i LANG=C LC_ALL=C PATH=/usr/bin:/bin \
        /usr/bin/python3 -I -S -c \
        'import hashlib, sys
digest = hashlib.sha256()
with open(sys.argv[1], "rb") as stream:
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        digest.update(chunk)
print(digest.hexdigest())' "$1"
}

artifact_hasher="$script_directory/hash-editor-find-f2-artifact.py"
artifact_hasher_mode=""
artifact_hasher_owner=""
artifact_hasher_digest=""
expected_artifact_hasher_digest="eb120ca20da97fed1308a77166435f6a95536d0af0a5222ed4a7bc5122b260a6"
if [[ -f "$artifact_hasher" && ! -L "$artifact_hasher" ]]; then
    artifact_hasher_mode="$(/usr/bin/stat -f '%Lp' "$artifact_hasher")"
    artifact_hasher_owner="$(/usr/bin/stat -f '%u' "$artifact_hasher")"
    if [[ "$artifact_hasher_owner" == "$(/usr/bin/id -u)" &&
        "$((8#$artifact_hasher_mode & 8#022))" == "0" ]] &&
        f2_reject_acl_allows "$artifact_hasher"; then
        artifact_hasher_digest="$(f2_sha256_file "$artifact_hasher")"
    fi
fi
if [[ ! -f "$artifact_hasher" || -L "$artifact_hasher" ||
    "$artifact_hasher_owner" != "$(/usr/bin/id -u)" ||
    -z "$artifact_hasher_mode" || "$((8#$artifact_hasher_mode & 8#022))" != "0" ||
    "$artifact_hasher_digest" != "$expected_artifact_hasher_digest" ]]; then
    echo "F2 artifact hasher is not the pinned owner-controlled file" >&2
    exit 2
fi

if [[ "$derived_data_path" != /* || "$derived_data_path" == *[[:space:]]* ||
    ! "${derived_data_path##*/}" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "F2 DerivedData must be an absolute path with a simple leaf" >&2
    exit 2
fi
derived_data_parent="$(/usr/bin/dirname "$derived_data_path")"
if [[ ! -d "$derived_data_parent" || -L "$derived_data_parent" ||
    "$(builtin cd "$derived_data_parent" && /bin/pwd -P)" != "$derived_data_parent" ]]; then
    echo "F2 DerivedData parent must be a real canonical directory" >&2
    exit 2
fi
derived_data_parent_owner="$(/usr/bin/stat -f '%u' "$derived_data_parent")"
derived_data_parent_mode="$(/usr/bin/stat -f '%Lp' "$derived_data_parent")"
if [[ "$derived_data_parent_owner" != "$(/usr/bin/id -u)" ||
    "$((8#$derived_data_parent_mode & 8#022))" != "0" ]] ||
    ! f2_reject_acl_allows "$derived_data_parent"; then
    echo "F2 DerivedData parent must be owner-controlled" >&2
    exit 2
fi

if [[ "$configuration" != "Debug" && "$configuration" != "Release" ]]; then
    echo "configuration must be Debug or Release, got: $configuration" >&2
    exit 2
fi
if [[ "${CI:-}" == "true" || "${GITHUB_ACTIONS:-}" == "true" ||
    "${TEST_RUNNER_CI:-}" == "true" ||
    "${TEST_RUNNER_GITHUB_ACTIONS:-}" == "true" ]]; then
    echo "authoritative F2 builds are local-only and reject CI budget mode" >&2
    exit 2
fi
if [[ -e "$derived_data_path" || -L "$derived_data_path" ||
    -e "$source_snapshot_path" || -L "$source_snapshot_path" ||
    -e "$source_archive_path" || -L "$source_archive_path" ]]; then
    echo "refusing to reuse an existing DerivedData/source artifact path" >&2
    echo "derived-data: $derived_data_path" >&2
    echo "source-snapshot: $source_snapshot_path" >&2
    echo "source-archive: $source_archive_path" >&2
    exit 2
fi

repository_root="$(builtin cd "$script_directory/.." && /bin/pwd -P)"
if [[ "$derived_data_path" == "$repository_root" ||
    "$derived_data_path" == "$repository_root/"* ]]; then
    echo "F2 DerivedData must be disjoint from the source repository" >&2
    exit 2
fi
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

worktree_status="$(
    trusted_git -C "$repository_root" status --porcelain=v1 --untracked-files=all
)"
if [[ -n "$worktree_status" ]]; then
    echo "authoritative F2 builds require a clean worktree:" >&2
    echo "$worktree_status" >&2
    exit 2
fi
source_commit="$(trusted_git -C "$repository_root" rev-parse HEAD)"
host_architecture="$(/usr/bin/uname -m)"
if [[ "$host_architecture" != "arm64" && "$host_architecture" != "x86_64" ]]; then
    echo "unsupported F2 performance host architecture: $host_architecture" >&2
    exit 2
fi
destination="platform=macOS,arch=$host_architecture"

xcodegen_path="/opt/homebrew/bin/xcodegen"
if [[ ! -x "$xcodegen_path" ]]; then
    xcodegen_path="/usr/local/bin/xcodegen"
fi
if [[ ! -x "$xcodegen_path" ]]; then
    echo "could not find XcodeGen at a supported absolute path" >&2
    exit 2
fi
xcodegen_sha256="$(f2_sha256_file "$xcodegen_path")"

trusted_git -C "$repository_root" archive \
    --format=tar --output="$source_archive_path" "$source_commit"
/bin/mkdir -p "$source_snapshot_path"
/usr/bin/tar -xf "$source_archive_path" -C "$source_snapshot_path"
source_archive_sha256="$(f2_sha256_file "$source_archive_path")"
source_tree_sha256="$(
    /usr/bin/python3 -I "$artifact_hasher" "$source_snapshot_path"
)"
/bin/chmod a-w "$source_archive_path"
source_archive_writable_entry="$(
    /usr/bin/find "$source_archive_path" -perm +0222 -print -quit
)"
if [[ -n "$source_archive_writable_entry" ]]; then
    echo "could not seal the exact-source F2 archive" >&2
    exit 1
fi

(
    builtin cd "$source_snapshot_path"
    "$xcodegen_path" generate
)

CI=false GITHUB_ACTIONS=false \
    TEST_RUNNER_CI=false TEST_RUNNER_GITHUB_ACTIONS=false \
    /usr/bin/xcodebuild \
    -resolvePackageDependencies \
    -project "$source_snapshot_path/Plainsong.xcodeproj" \
    -scheme Plainsong \
    -derivedDataPath "$derived_data_path"

build_input_sha256="$(
    /usr/bin/python3 -I "$artifact_hasher" "$source_snapshot_path"
)"
package_input_path="$derived_data_path/SourcePackages"
if [[ ! -d "$package_input_path/checkouts" ||
    ! -d "$package_input_path/artifacts" ||
    ! -f "$package_input_path/workspace-state.json" ]]; then
    echo "resolved F2 SwiftPM build input is incomplete" >&2
    exit 1
fi
resolved_package_input_sha256="$(
    /usr/bin/python3 -I "$artifact_hasher" \
        --resolved-package-input "$package_input_path"
)"
/bin/chmod -R a-w "$source_snapshot_path"
# SwiftPM's bare repositories and checkout .git entries are mutable
# administrative caches. Seal the resolved state and bytes the build consumes.
/usr/bin/find "$package_input_path/checkouts" \
    -name .git -prune -o -exec /bin/chmod a-w {} +
/bin/chmod -R a-w "$package_input_path/artifacts"
/bin/chmod a-w "$package_input_path/workspace-state.json"
source_snapshot_writable_entry="$(
    /usr/bin/find "$source_snapshot_path" -perm +0222 -print -quit
)"
if ! resolved_package_input_writable_entry="$(
    /usr/bin/find "$package_input_path/checkouts" \
        -name .git -prune -o -perm +0222 -print -quit &&
        /usr/bin/find "$package_input_path/artifacts" \
            -perm +0222 -print -quit &&
        /usr/bin/find "$package_input_path/workspace-state.json" \
            -perm +0222 -print -quit
)"; then
    echo "could not verify resolved F2 package-input permissions" >&2
    exit 1
fi
sealed_build_input_sha256="$(
    /usr/bin/python3 -I "$artifact_hasher" "$source_snapshot_path"
)"
sealed_resolved_package_input_sha256="$(
    /usr/bin/python3 -I "$artifact_hasher" \
        --resolved-package-input "$package_input_path"
)"
if [[ -n "$source_snapshot_writable_entry" ||
    -n "$resolved_package_input_writable_entry" ||
    "$sealed_build_input_sha256" != "$build_input_sha256" ||
    "$sealed_resolved_package_input_sha256" != "$resolved_package_input_sha256" ]]; then
    echo "could not seal the exact-source F2 build input" >&2
    echo "writable-entry: $source_snapshot_writable_entry" >&2
    echo "resolved-package-input-writable-entry: $resolved_package_input_writable_entry" >&2
    exit 1
fi

arguments=(
    -project "$source_snapshot_path/Plainsong.xcodeproj"
    -scheme Plainsong
    -configuration "$configuration"
    -derivedDataPath "$derived_data_path"
    -disableAutomaticPackageResolution
    -only-testing:PerformanceTests/EditorFindPerformanceTests
)
if [[ "$configuration" == "Release" ]]; then
    arguments+=(ENABLE_TESTABILITY=YES)
fi
arguments+=(build-for-testing)
CI=false GITHUB_ACTIONS=false \
    TEST_RUNNER_CI=false TEST_RUNNER_GITHUB_ACTIONS=false \
    /usr/bin/xcodebuild "${arguments[@]}"

postbuild_status="$(
    trusted_git -C "$repository_root" status --porcelain=v1 --untracked-files=all
)"
postbuild_commit="$(trusted_git -C "$repository_root" rev-parse HEAD)"
postbuild_source_archive_sha256="$(f2_sha256_file "$source_archive_path")"
postbuild_input_sha256="$(
    /usr/bin/python3 -I "$artifact_hasher" "$source_snapshot_path"
)"
postbuild_resolved_package_input_sha256="$(
    /usr/bin/python3 -I "$artifact_hasher" \
        --resolved-package-input "$package_input_path"
)"
postbuild_source_writable_entry="$(
    /usr/bin/find "$source_snapshot_path" -perm +0222 -print -quit
)"
if ! postbuild_resolved_package_input_writable_entry="$(
    /usr/bin/find "$package_input_path/checkouts" \
        -name .git -prune -o -perm +0222 -print -quit &&
        /usr/bin/find "$package_input_path/artifacts" \
            -perm +0222 -print -quit &&
        /usr/bin/find "$package_input_path/workspace-state.json" \
            -perm +0222 -print -quit
)"; then
    echo "could not reverify resolved F2 package-input permissions" >&2
    exit 1
fi
postbuild_source_archive_writable_entry="$(
    /usr/bin/find "$source_archive_path" -perm +0222 -print -quit
)"
if [[ -n "$postbuild_status" || "$postbuild_commit" != "$source_commit" ||
    "$postbuild_source_archive_sha256" != "$source_archive_sha256" ||
    "$postbuild_input_sha256" != "$build_input_sha256" ||
    "$postbuild_resolved_package_input_sha256" != "$resolved_package_input_sha256" ||
    -n "$postbuild_source_archive_writable_entry" ||
    -n "$postbuild_source_writable_entry" ||
    -n "$postbuild_resolved_package_input_writable_entry" ]]; then
    echo "source checkout changed during the authoritative F2 build" >&2
    echo "$postbuild_status" >&2
    echo "started: $source_commit" >&2
    echo "ended: $postbuild_commit" >&2
    echo "source-archive-writable-entry: $postbuild_source_archive_writable_entry" >&2
    echo "source-snapshot-writable-entry: $postbuild_source_writable_entry" >&2
    echo "resolved-package-input-writable-entry: $postbuild_resolved_package_input_writable_entry" >&2
    exit 1
fi

products_directory="$derived_data_path/Build/Products/$configuration"
host_bundle="$products_directory/Plainsong.app"
performance_test_bundle="$host_bundle/Contents/PlugIns/PerformanceTests.xctest"
if [[ ! -d "$host_bundle" || ! -d "$performance_test_bundle" ]]; then
    echo "F2 host or PerformanceTests bundle is missing after build-for-testing" >&2
    echo "host: $host_bundle" >&2
    echo "test: $performance_test_bundle" >&2
    exit 1
fi

xctestrun_path=""
xctestrun_count=0
while IFS= read -r candidate; do
    xctestrun_path="$candidate"
    xctestrun_count=$((xctestrun_count + 1))
done < <(
    /usr/bin/find "$derived_data_path/Build/Products" \
        -maxdepth 1 -type f -name '*.xctestrun' -print
)
if [[ "$xctestrun_count" -ne 1 ]]; then
    echo "expected exactly one F2 .xctestrun file, found $xctestrun_count" >&2
    exit 1
fi
xctestrun_relative_path="${xctestrun_path#"$derived_data_path/"}"
if [[ "$xctestrun_relative_path" == "$xctestrun_path" ]]; then
    echo "F2 .xctestrun file is outside DerivedData: $xctestrun_path" >&2
    exit 1
fi

host_bundle_sha256="$(/usr/bin/python3 -I "$artifact_hasher" "$host_bundle")"
xctestrun_sha256="$(/usr/bin/python3 -I "$artifact_hasher" "$xctestrun_path")"
if ! f2_reject_tree_acls "$source_archive_path" ||
    ! f2_reject_tree_acls "$source_snapshot_path" ||
    ! f2_reject_tree_acls "$derived_data_path"; then
    echo "F2 build inputs/products contain an ACL or ACL inspection failed" >&2
    exit 1
fi
manifest_path="$derived_data_path/f2-editor-find-build-manifest.txt"
{
    printf 'format=5\n'
    printf 'source_commit=%s\n' "$source_commit"
    printf 'configuration=%s\n' "$configuration"
    printf 'repository_root=%s\n' "$repository_root"
    printf 'source_snapshot_path=%s\n' "$source_snapshot_path"
    printf 'source_archive_path=%s\n' "$source_archive_path"
    printf 'source_archive_sha256=%s\n' "$source_archive_sha256"
    printf 'source_tree_sha256=%s\n' "$source_tree_sha256"
    printf 'build_input_sha256=%s\n' "$build_input_sha256"
    printf 'package_input_path=%s\n' "$package_input_path"
    printf 'resolved_package_input_sha256=%s\n' "$resolved_package_input_sha256"
    printf 'xcodegen_path=%s\n' "$xcodegen_path"
    printf 'xcodegen_sha256=%s\n' "$xcodegen_sha256"
    printf 'destination=%s\n' "$destination"
    printf 'budget_mode=local-hard\n'
    printf 'host_bundle_sha256=%s\n' "$host_bundle_sha256"
    printf 'xctestrun_relative_path=%s\n' "$xctestrun_relative_path"
    printf 'xctestrun_sha256=%s\n' "$xctestrun_sha256"
} > "$manifest_path"
/bin/chmod a-w "$manifest_path"

echo "F2 BUILD MANIFEST PASS commit=$source_commit configuration=$configuration"
echo "manifest: $manifest_path"
echo "source-snapshot: $source_snapshot_path"
echo "source-archive-sha256: $source_archive_sha256"
echo "source-tree-sha256: $source_tree_sha256"
echo "sealed-build-input-sha256: $build_input_sha256"
echo "sealed-resolved-package-input-sha256: $resolved_package_input_sha256"
echo "xcodegen-sha256: $xcodegen_sha256"
echo "destination: $destination"
echo "host-bundle-sha256: $host_bundle_sha256"
echo "xctestrun: $xctestrun_relative_path"
echo "xctestrun-sha256: $xctestrun_sha256"
