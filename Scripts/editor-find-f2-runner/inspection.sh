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
    if ! f2_reject_tree_acls "$inspection_result_bundle_path"; then
        echo "F2 inspection xcresult contains an ACL or ACL inspection failed" >&2
        return 1
    fi
    if ! current_sha256="$(
        /usr/bin/python3 -I "$artifact_hasher" "$inspection_result_bundle_path"
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
evidence_manifest_sha256="$(f2_sha256_file "$evidence_manifest_path")"

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
    if ! f2_reject_tree_acls "$evidence_manifest_path"; then
        echo "F2 evidence manifest contains an ACL or ACL inspection failed" >&2
        return 1
    fi
    if ! current_sha256="$(f2_sha256_file "$evidence_manifest_path")"; then
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

echo "F2 FINAL INTEGRITY PASS commit=$source_commit configuration=$configuration build-manifest-readonly=true build-manifest-sha256=$manifest_sha256 exact-source-readonly=true resolved-package-input-readonly=true resolved-package-input-sha256=$manifest_resolved_package_input_sha256 snapshot-readonly=true raw-log-readonly=true raw-log-sha256=$captured_log_sha256 xcresult-readonly=true xcresult-sha256=$result_bundle_sha256 xcresult-inspection-readonly=true xcresult-inspection-input-sha256=$inspection_input_sha256 xcresult-inspection-result-sha256=$inspection_result_sha256 warning-check-readonly=true warning-check-sha256=$warning_check_sha256 evidence-manifest-readonly=true evidence-manifest-sha256=$evidence_manifest_sha256"
