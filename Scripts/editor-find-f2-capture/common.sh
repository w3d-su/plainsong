#!/bin/bash

F2_SOURCE_COMMIT="c871ddf5c66c17f03fd9456b53f79411f9b2e979"
F2_PROCESS_FILTER="xcodebuild|swift-frontend|swiftc|swift-driver|xctest|Plainsong|PlainsongUITests-Runner"
F2_PROCESS_OWNERSHIP_RULE="runner-process-group-single-frozen-host"
F2_MONITOR_FORMAT=5
F2_MONITOR_INTERVAL_MS=200
F2_MONITOR_MAX_GAP_MS=1000
F2_OUTER_FORMAT=3
F2_RUN_TIMEOUT_SECONDS=180
F2_RUNNER_ENVIRONMENT_POLICY="env-i-git-no-replace-home-lang-lc-all-path-tmpdir-user-logname"

f2_die() {
    echo "F2 CAPTURE FAIL: $*" >&2
    return 1
}

f2_utc_now() {
    /usr/bin/env -i LANG=C LC_ALL=C PATH=/usr/bin:/bin \
        /usr/bin/python3 -I -c \
        'from datetime import datetime, timezone; print(datetime.now(timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z"))'
}

f2_trusted_git() {
    /usr/bin/env -i \
        GIT_CONFIG_GLOBAL=/dev/null \
        GIT_CONFIG_NOSYSTEM=1 \
        GIT_NO_REPLACE_OBJECTS=1 \
        LANG=C \
        LC_ALL=C \
        PATH=/usr/bin:/bin \
        /usr/bin/git --no-replace-objects "$@"
}

f2_require_canonical_directory() {
    local path="$1"
    local label="$2"

    [[ "$path" == /* && -d "$path" && ! -L "$path" &&
        "$path" != *[[:space:]]* &&
        "$(builtin cd "$path" && /bin/pwd -P)" == "$path" ]] ||
        f2_die "$label must be a real canonical whitespace-free directory: $path"
}

f2_reject_acl_allows() {
    local listing

    listing="$(LC_ALL=C /bin/ls -lde "$1")" || return
    [[ "$listing" != *$'\n'*" allow " ]]
}

f2_require_owner_controlled_directory() {
    local path="$1"
    local label="$2"
    local mode

    f2_require_canonical_directory "$path" "$label" || return
    mode="$(/usr/bin/stat -f '%Lp' "$path")" || return
    [[ "$(/usr/bin/stat -f '%u' "$path")" == "$(/usr/bin/id -u)" &&
        "$((8#$mode & 8#022))" == 0 ]] ||
        f2_die "$label must be owned by the current user and not group/world-writable" || return
    f2_reject_acl_allows "$path" ||
        f2_die "$label must not carry an ACL allow entry"
}

f2_require_owner_directory() {
    local path="$1"
    local label="$2"

    f2_require_owner_controlled_directory "$path" "$label" || return
    [[ "$(/usr/bin/stat -f '%u' "$path")" == "$(/usr/bin/id -u)" &&
        "$(/usr/bin/stat -f '%Lp' "$path")" == "700" ]] ||
        f2_die "$label must be owned by the current user with mode 0700"
}

f2_write_digest() {
    local input_path="$1"
    local digest_path="$2"
    local digest
    local bytes

    digest="$(
        /usr/bin/env -i LANG=C LC_ALL=C PATH=/usr/bin:/bin \
            /usr/bin/python3 -I -S -c \
            'import hashlib, sys
digest = hashlib.sha256()
with open(sys.argv[1], "rb") as stream:
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        digest.update(chunk)
print(digest.hexdigest())' "$input_path"
    )" || return
    bytes="$(/usr/bin/stat -f '%z' "$input_path")" || return
    {
        printf 'sha256=%s\n' "$digest"
        printf 'bytes=%s\n' "$bytes"
    } > "$digest_path"
}

f2_validate_schema() {
    local schema_path="$F2_SCRIPT_DIRECTORY/editor-find-f2-evidence/schema.json"

    /usr/bin/python3 -I "$F2_SCRIPT_DIRECTORY/editor-find-f2-evidence/schema_check.py" \
        "$schema_path" \
        "$F2_SOURCE_COMMIT" \
        "$F2_PROCESS_FILTER" \
        "$F2_PROCESS_OWNERSHIP_RULE" \
        "$F2_MONITOR_FORMAT" \
        "$F2_MONITOR_INTERVAL_MS" \
        "$F2_MONITOR_MAX_GAP_MS" \
        "$F2_OUTER_FORMAT" \
        "$F2_RUN_TIMEOUT_SECONDS" \
        "$F2_RUNNER_ENVIRONMENT_POLICY"
}

f2_capture_tooling_digest() {
    /usr/bin/python3 -I "$F2_SCRIPT_DIRECTORY/editor-find-f2-evidence/schema_check.py" \
        --digest \
        "$F2_SCRIPT_DIRECTORY/editor-find-f2-evidence/schema.json" \
        capture \
        "$F2_SCRIPT_DIRECTORY"
}

f2_capture_boundary() {
    local phase="$1"
    local capture_path="$2"
    local digest_path="$3"
    local processes
    local process_count
    local commit
    local status
    local captured
    local thermal
    local power
    local load

    processes="$(f2_competitor_processes 0)" || return
    process_count="$(printf '%s\n' "$processes" | /usr/bin/awk 'NF {n++} END {print n+0}')"
    commit="$(f2_trusted_git -C "$F2_SOURCE_ROOT" rev-parse HEAD)" || return
    status="$(f2_trusted_git -C "$F2_SOURCE_ROOT" status --porcelain=v1 --untracked-files=all)" || return
    thermal="$(/usr/bin/pmset -g therm)" || return
    power="$(/usr/bin/pmset -g batt | /usr/bin/head -1)" || return
    load="$(/usr/sbin/sysctl -n vm.loadavg | /usr/bin/awk '{print $2}')" || return
    captured="$(f2_utc_now)" || return

    {
        printf 'format=1\n'
        printf 'phase=%s\n' "$phase"
        printf 'captured_utc=%s\n' "$captured"
        printf 'source_commit=%s\n' "$commit"
        if [[ "$commit" == "$F2_SOURCE_COMMIT" && -z "$status" ]]; then
            printf 'source_status=clean\n'
        else
            printf 'source_status=dirty\n'
        fi
        printf 'process_filter=%s\n' "$F2_PROCESS_FILTER"
        printf 'competing_process_lines=%s\n' "$process_count"
        printf 'load_average_1m=%s\n' "$load"
        if [[ "$thermal" == *"No thermal warning level has been recorded"* &&
            "$thermal" == *"No performance warning level has been recorded"* ]]; then
            printf 'thermal_warning=none\n'
        else
            printf 'thermal_warning=warning\n'
        fi
        if [[ "$power" == *"'AC Power'"* ]]; then
            printf 'power_source=AC\n'
        else
            printf 'power_source=non-AC\n'
        fi
    } > "$capture_path"
    f2_write_digest "$capture_path" "$digest_path" || return
    /bin/chmod a-w "$capture_path" "$digest_path" || return

    [[ "$commit" == "$F2_SOURCE_COMMIT" && -z "$status" &&
        "$process_count" == 0 &&
        "$thermal" == *"No thermal warning level has been recorded"* &&
        "$thermal" == *"No performance warning level has been recorded"* &&
        "$power" == *"'AC Power'"* ]] || {
        printf '%s\n' "$processes" >&2
        return 1
    }
}
