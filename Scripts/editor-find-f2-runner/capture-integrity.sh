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
    if ! f2_reject_tree_acls "$output_path" ||
        ! f2_reject_tree_acls "$digest_path"; then
        echo "F2 streaming capture contains an ACL or ACL inspection failed" >&2
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
    if ! actual_sha256="$(f2_sha256_file "$output_path")"; then
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

if [[ ! -d "$result_bundle_path" || -L "$result_bundle_path" ]]; then
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
if ! f2_reject_tree_acls "$result_bundle_path"; then
    echo "F2 xcresult contains an ACL or ACL inspection failed" >&2
    exit 1
fi
result_bundle_sha256="$(
    /usr/bin/python3 -I "$artifact_hasher" "$result_bundle_path"
)"
/usr/bin/ditto --noextattr --noqtn --noacl \
    "$result_bundle_path" "$inspection_result_bundle_path"
/bin/chmod -R u+w "$inspection_result_bundle_path"
inspection_input_sha256="$(
    /usr/bin/python3 -I "$artifact_hasher" "$inspection_result_bundle_path"
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
    if ! f2_reject_tree_acls "$result_bundle_path"; then
        echo "F2 xcresult contains an ACL or ACL inspection failed" >&2
        return 1
    fi
    if ! current_result_sha256="$(
        /usr/bin/python3 -I "$artifact_hasher" "$result_bundle_path"
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

    if [[ ! -d "$inspection_result_bundle_path" ||
        -L "$inspection_result_bundle_path" ]]; then
        echo "F2 xcresult inspection input is missing" >&2
        return 1
    fi
    if ! current_sha256="$(
        /usr/bin/python3 -I "$artifact_hasher" "$inspection_result_bundle_path"
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

source_check_line="F2 SOURCE CHECK PASS commit=$source_commit configuration=$configuration budget-mode=$manifest_budget_mode build-manifest-readonly=true build-manifest-sha256=$manifest_sha256 exact-source-readonly=true build-input-sha256=$manifest_build_input_sha256 resolved-package-input-readonly=true resolved-package-input-sha256=$manifest_resolved_package_input_sha256 snapshot-readonly=true frozen-products=$snapshot_root host-bundle-sha256=$manifest_host_bundle_sha256 xctestrun-sha256=$manifest_xctestrun_sha256 raw-log-readonly=true raw-log-sha256=$captured_log_sha256 xcresult-readonly=true xcresult-sha256=$result_bundle_sha256 xcresult-inspection-input-sha256=$inspection_input_sha256"

set +e
{
    echo "$source_check_line"
    /usr/bin/python3 -I "$checker" \
        "$log_path" "$inspection_result_bundle_path" \
        "$captured_log_sha256" "$result_bundle_sha256"
} 2>&1 |
    /usr/bin/python3 -I "$stream_capturer" \
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
    /usr/bin/python3 -I "$artifact_hasher" "$inspection_result_bundle_path"
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
