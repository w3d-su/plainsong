verify_build_source_snapshot() {
    local build_input_sha256
    local source_archive_sha256
    local source_archive_writable_entry
    local writable_entry

    if [[ ! -d "$manifest_source_snapshot_path" ||
        -L "$manifest_source_snapshot_path" ||
        ! -f "$manifest_source_archive_path" ||
        -L "$manifest_source_archive_path" ||
        ! -f "$checker" || -L "$checker" ||
        ! -f "$artifact_hasher" || -L "$artifact_hasher" ||
        ! -f "$stream_capturer" || -L "$stream_capturer" ]]; then
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
    if ! f2_reject_tree_acls "$manifest_source_snapshot_path" ||
        ! f2_reject_tree_acls "$manifest_source_archive_path"; then
        echo "F2 exact-source build artifacts contain an ACL or ACL inspection failed" >&2
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
        f2_sha256_file "$manifest_source_archive_path"
    )"; then
        echo "could not hash the F2 source archive" >&2
        return 1
    fi
    if ! build_input_sha256="$(
        /usr/bin/python3 -I "$bootstrap_artifact_hasher" \
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
    local resolved_package_input_sha256
    local writable_entry

    if [[ -L "$manifest_package_input_path" ||
        ! -d "$manifest_package_input_path/checkouts" ||
        -L "$manifest_package_input_path/checkouts" ||
        ! -d "$manifest_package_input_path/artifacts" ||
        -L "$manifest_package_input_path/artifacts" ||
        ! -f "$manifest_package_input_path/workspace-state.json" ||
        -L "$manifest_package_input_path/workspace-state.json" ]]; then
        echo "F2 resolved SwiftPM package input is incomplete" >&2
        return 1
    fi
    if ! writable_entry="$(
        /usr/bin/find "$manifest_package_input_path/checkouts" \
            -name .git -prune -o -perm +0222 -print -quit &&
            /usr/bin/find "$manifest_package_input_path/artifacts" \
                -perm +0222 -print -quit &&
            /usr/bin/find "$manifest_package_input_path/workspace-state.json" \
                -perm +0222 -print -quit
    )"; then
        echo "could not verify F2 resolved-package-input permissions" >&2
        return 1
    fi
    if [[ -n "$writable_entry" ]]; then
        echo "F2 resolved package input is not read-only: $writable_entry" >&2
        return 1
    fi
    if ! f2_reject_tree_acls "$manifest_package_input_path/checkouts" ||
        ! f2_reject_tree_acls "$manifest_package_input_path/artifacts" ||
        ! f2_reject_tree_acls "$manifest_package_input_path/workspace-state.json"; then
        echo "F2 resolved package input contains an ACL or ACL inspection failed" >&2
        return 1
    fi
    if ! resolved_package_input_sha256="$(
        /usr/bin/python3 -I "$artifact_hasher" \
            --resolved-package-input "$manifest_package_input_path"
    )"; then
        echo "could not hash the F2 resolved package input" >&2
        return 1
    fi
    if [[ "$resolved_package_input_sha256" != "$manifest_resolved_package_input_sha256" ]]; then
        echo "F2 resolved package input differs from the build manifest" >&2
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

    if [[ ! -d "$host_bundle" || -L "$host_bundle" ||
        ! -d "$performance_test_bundle" || -L "$performance_test_bundle" ||
        ! -f "$xctestrun_path" || -L "$xctestrun_path" ]]; then
        echo "F2 host, PerformanceTests, or .xctestrun artifact is missing" >&2
        return 1
    fi
    if ! host_bundle_sha256="$(
        /usr/bin/python3 -I "$artifact_hasher" "$host_bundle"
    )"; then
        echo "could not hash the F2 host bundle" >&2
        return 1
    fi
    if ! xctestrun_sha256="$(
        /usr/bin/python3 -I "$artifact_hasher" "$xctestrun_path"
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

    if [[ ! -d "$snapshot_root" || -L "$snapshot_root" ||
        ! -d "$snapshot_host_bundle" || -L "$snapshot_host_bundle" ||
        ! -d "$snapshot_host_bundle/Contents/PlugIns/PerformanceTests.xctest" ||
        -L "$snapshot_host_bundle/Contents/PlugIns/PerformanceTests.xctest" ||
        ! -f "$snapshot_xctestrun_path" || -L "$snapshot_xctestrun_path" ]]; then
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
    if ! f2_reject_tree_acls "$snapshot_root"; then
        echo "F2 product snapshot contains an ACL or ACL inspection failed" >&2
        return 1
    fi
    if ! host_bundle_sha256="$(
        /usr/bin/python3 -I "$artifact_hasher" "$snapshot_host_bundle"
    )"; then
        echo "could not hash the F2 snapshot host bundle" >&2
        return 1
    fi
    if ! xctestrun_sha256="$(
        /usr/bin/python3 -I "$artifact_hasher" "$snapshot_xctestrun_path"
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
        trusted_git -C "$repository_root" \
            status --porcelain=v1 --untracked-files=all
    )"; then
        echo "could not inspect the F2 source checkout status" >&2
        return 1
    fi
    if ! current_commit="$(
        trusted_git -C "$repository_root" rev-parse HEAD
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

    if [[ ! -f "$manifest_path" || -L "$manifest_path" ]]; then
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
    if ! current_sha256="$(f2_sha256_file "$manifest_path")"; then
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
    /usr/bin/python3 -I "$stream_capturer" "$log_path" "$log_digest_path"
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
