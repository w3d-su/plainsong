#!/bin/bash

set -euo pipefail
/usr/bin/umask 077

if [[ "$#" -ne 4 ]]; then
    echo "usage: $0 CONFIGURATION SOURCE_ROOT DERIVED_DATA_PATH OUTPUT_PREFIX" >&2
    exit 2
fi

configuration="$1"
source_root="$2"
derived_data_path="$3"
output_prefix="$4"
source_commit="c871ddf5c66c17f03fd9456b53f79411f9b2e979"
process_filter="xcodebuild|swift-frontend|swiftc|swift-driver|xctest|Plainsong|PlainsongUITests-Runner"
runner="$source_root/Scripts/run-editor-find-f2-performance-gate.sh"
control_directory=""
control_directory_identity=""
monitor_pid=""
run_pid=""
run_active=0
termination_failed=0
done_signal=""
run_timeout_seconds=180
runner_environment_policy="env-i-git-no-replace-home-lang-lc-all-path-tmpdir-user-logname"
process_ownership_rule="runner-ancestry-or-private-output-prefix-correlation"

if [[ "$configuration" != "Debug" && "$configuration" != "Release" ]]; then
    echo "configuration must be Debug or Release, got: $configuration" >&2
    exit 2
fi
if [[ ! -x "$runner" || ! -d "$derived_data_path" ]]; then
    echo "missing exact-source F2 runner or DerivedData" >&2
    exit 2
fi
if [[ "$output_prefix" != /* ]]; then
    echo "F2 output prefix must be absolute" >&2
    exit 2
fi

output_directory="${output_prefix%/*}"
output_basename="${output_prefix##*/}"
allowed_host_executable="$output_prefix.products/Build/Products/$configuration/Plainsong.app/Contents/MacOS/Plainsong"
if [[ -z "$output_directory" || -z "$output_basename" ||
    ! "$output_basename" =~ ^[A-Za-z0-9._-]+$ ||
    "$output_prefix" == *[[:space:]]* ||
    ! -d "$output_directory" || -L "$output_directory" ||
    "$(cd "$output_directory" && /bin/pwd -P)" != "$output_directory" ]]; then
    echo "F2 output prefix must name a simple leaf in a real canonical directory" >&2
    exit 2
fi
output_owner="$(/usr/bin/stat -f '%u' "$output_directory")"
output_mode="$(/usr/bin/stat -f '%Lp' "$output_directory")"
if [[ "$output_owner" != "$(/usr/bin/id -u)" || "$output_mode" != "700" ]]; then
    echo "F2 output directory must be owner-controlled mode 0700" >&2
    exit 2
fi
for exact_directory in "$source_root" "$derived_data_path"; do
    if [[ "$exact_directory" != /* || ! -d "$exact_directory" ||
        "$exact_directory" == *[[:space:]]* ||
        -L "$exact_directory" ||
        "$(cd "$exact_directory" && /bin/pwd -P)" != "$exact_directory" ]]; then
        echo "F2 source/build path is not a real canonical directory: $exact_directory" >&2
        exit 2
    fi
done
runner_user="$(/usr/bin/id -un)"
runner_home="$(
    /usr/bin/env -i LANG=C LC_ALL=C PATH=/usr/bin:/bin \
        /usr/bin/python3 -I -c \
        'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)'
)"
runner_tmpdir="/private/tmp"
if [[ "$runner_home" != /* || "$runner_tmpdir" != /* ||
    ! -d "$runner_home" || ! -d "$runner_tmpdir" ||
    "$runner_home" == *$'\n'* || "$runner_tmpdir" == *$'\n'* ||
    ! "$runner_user" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "F2 runner allowlisted environment is invalid" >&2
    exit 2
fi

utc_now() {
    /usr/bin/env -i LANG=C LC_ALL=C PATH=/usr/bin:/bin \
        /usr/bin/python3 -I -c \
        'from datetime import datetime, timezone; print(datetime.now(timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z"))'
}

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

write_digest() {
    local input_path="$1"
    local digest_path="$2"
    local digest
    local byte_count

    if ! digest="$(/usr/bin/shasum -a 256 "$input_path" | /usr/bin/awk '{print $1}')"; then
        return 1
    fi
    if ! byte_count="$(/usr/bin/stat -f '%z' "$input_path")"; then
        return 1
    fi
    {
        printf 'sha256=%s\n' "$digest"
        printf 'bytes=%s\n' "$byte_count"
    } > "$digest_path" || return 1
}

matching_processes() {
    local allowed_runner_pid="${1:-0}"
    local allow_run_path_correlation="${2:-0}"
    local sample_sequence="${3:-0}"
    local sample_started_utc="${4:-}"
    local candidate_lines
    local candidate_pid
    local candidate_parent
    local candidate_process_group
    local candidate_executable
    local candidate_command
    local correlated
    local correlation_reason
    local executable_base64
    local command_base64
    local matched_token
    local matched_token_base64

    if [[ ! "$allowed_runner_pid" =~ ^[0-9]+$ ||
        "$allow_run_path_correlation" != "0" &&
        "$allow_run_path_correlation" != "1" ||
        ! "$sample_sequence" =~ ^[0-9]+$ ||
        "$allow_run_path_correlation" == "1" &&
        ! "$sample_started_utc" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]; then
        return 2
    fi
    if ! candidate_lines="$(
        /bin/ps -ww -axo pid=,ppid=,pgid=,comm= | /usr/bin/awk \
        -v allowed_runner_pid="$allowed_runner_pid" \
        '
    function belongs_to_run(candidate, current, steps) {
        if (allowed_runner_pid == 0) return 0
        current = candidate
        for (steps = 0; steps < 4096 && current != 0; steps++) {
            if (current == allowed_runner_pid) return 1
            if (!(current in parent) || parent[current] == current) return 0
            current = parent[current]
        }
        return 0
    }
    {
        pid=$1
        parent[pid]=$2
        executable=$0
        process_group[pid]=$3
        sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]+/, "", executable)
        component_count=split(executable, components, "/")
        executable_name=components[component_count]
        if (executable_name ~ /^(xcodebuild|swift-frontend|swiftc|swift-driver|xctest|Plainsong|PlainsongUITests-Runner)$/) {
            tracked[pid]=pid "\t" parent[pid] "\t" process_group[pid] "\t" executable
        }
    }
    END {
        for (pid in tracked) {
            if (!belongs_to_run(pid)) print tracked[pid]
        }
    }'
    )"; then
        return 1
    fi
    while IFS=$'\t' read -r \
        candidate_pid candidate_parent candidate_process_group candidate_executable; do
        if [[ -z "$candidate_pid" ]]; then
            continue
        fi
        if ! candidate_command="$(
            /bin/ps -ww -p "$candidate_pid" -o command=
        )"; then
            if /bin/kill -0 "$candidate_pid" 2>/dev/null; then
                return 1
            fi
            if [[ "$allow_run_path_correlation" == "1" &&
                "$candidate_executable" == "$allowed_host_executable" ]]; then
                matched_token="$candidate_executable"
                candidate_command="<exited-before-command-capture>"
                if ! executable_base64="$(
                    printf '%s' "$candidate_executable" | /usr/bin/base64 -b 0
                )" || ! command_base64="$(
                    printf '%s' "$candidate_command" | /usr/bin/base64 -b 0
                )" || ! matched_token_base64="$(
                    printf '%s' "$matched_token" | /usr/bin/base64 -b 0
                )"; then
                    return 1
                fi
                printf 'sequence=%s sample_started_utc=%s pid=%s ppid=%s pgid=%s reason=%s executable_base64=%s matched_token_base64=%s command_base64=%s\n' \
                    "$sample_sequence" \
                    "$sample_started_utc" \
                    "$candidate_pid" \
                    "$candidate_parent" \
                    "$candidate_process_group" \
                    "exact-host-exited-before-command-capture" \
                    "$executable_base64" \
                    "$matched_token_base64" \
                    "$command_base64" >> "$output_prefix.run-owned-processes.log" || return 1
            else
                printf '%s %s %s command=<exited-before-command-capture>\n' \
                    "$candidate_pid" \
                    "$candidate_parent" \
                    "$candidate_executable"
            fi
            continue
        fi
        correlated=0
        correlation_reason=""
        matched_token=""
        if [[ "$allow_run_path_correlation" == "1" ]]; then
            if [[ "$candidate_executable" == "$allowed_host_executable" ]]; then
                correlated=1
                correlation_reason="exact-host-executable"
                matched_token="$candidate_executable"
            elif matched_token="$(
                printf '%s\n' "$candidate_command" | /usr/bin/awk \
                -v output_prefix="$output_prefix" '
                {
                    for (field_index = 1; field_index <= NF; field_index++) {
                        if ($field_index == output_prefix ||
                            substr($field_index, 1, length(output_prefix) + 1) == output_prefix "." ||
                            substr($field_index, 1, length(output_prefix) + 1) == output_prefix "/") {
                            print $field_index
                            found=1
                            exit
                        }
                    }
                }
                END { exit(found ? 0 : 1) }'
            )"; then
                correlated=1
                correlation_reason="output-prefix-command-token"
            fi
        fi
        if [[ "$correlated" == "1" ]]; then
            if ! executable_base64="$(
                printf '%s' "$candidate_executable" | /usr/bin/base64 -b 0
            )" || ! command_base64="$(
                printf '%s' "$candidate_command" | /usr/bin/base64 -b 0
            )" || ! matched_token_base64="$(
                printf '%s' "$matched_token" | /usr/bin/base64 -b 0
            )"; then
                return 1
            fi
            printf 'sequence=%s sample_started_utc=%s pid=%s ppid=%s pgid=%s reason=%s executable_base64=%s matched_token_base64=%s command_base64=%s\n' \
                "$sample_sequence" \
                "$sample_started_utc" \
                "$candidate_pid" \
                "$candidate_parent" \
                "$candidate_process_group" \
                "$correlation_reason" \
                "$executable_base64" \
                "$matched_token_base64" \
                "$command_base64" >> "$output_prefix.run-owned-processes.log" || return 1
        else
            printf '%s %s %s command=%s\n' \
                "$candidate_pid" \
                "$candidate_parent" \
                "$candidate_executable" \
                "$candidate_command"
        fi
    done <<< "$candidate_lines"
}

control_directory_is_exact() {
    local current_identity
    local current_mode
    local current_owner

    [[ -n "$control_directory" &&
        "$control_directory" == /private/tmp/plainsong-f2-monitor.* &&
        -d "$control_directory" && ! -L "$control_directory" ]] || return 1
    current_identity="$(/usr/bin/stat -f '%d:%i' "$control_directory")" || return 1
    current_owner="$(/usr/bin/stat -f '%u' "$control_directory")" || return 1
    current_mode="$(/usr/bin/stat -f '%Lp' "$control_directory")" || return 1
    [[ "$current_identity" == "$control_directory_identity" &&
        "$current_owner" == "$(/usr/bin/id -u)" &&
        "$current_mode" == "700" ]]
}

cleanup_control_directory() {
    if [[ -z "$control_directory" ]]; then
        return 0
    fi
    if ! control_directory_is_exact; then
        echo "refusing monitor-control cleanup after identity change" >&2
        return 1
    fi
    /bin/rm -rf -- "$control_directory" || return 1
    control_directory=""
    control_directory_identity=""
}

owned_host_processes() {
    /bin/ps -ww -axo pid=,comm= | /usr/bin/awk \
        -v allowed_host_executable="$allowed_host_executable" '
    {
        pid=$1
        executable=$0
        sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", executable)
        if (executable == allowed_host_executable) print pid
    }'
}

process_group_live_state() {
    local process_group_id="$1"

    /bin/ps -axo pid=,pgid=,state= | /usr/bin/awk \
        -v process_group_id="$process_group_id" '
    $2 == process_group_id && $3 !~ /^Z/ { live=1 }
    END { print live + 0 }'
}

terminate_run_tree() {
    local host_pid
    local host_pids=""
    local group_alive=0
    local root_alive=0
    local root_state

    if [[ "$run_active" != "1" || -z "$run_pid" ||
        ! "$run_pid" =~ ^[0-9]+$ ]]; then
        return 0
    fi
    /bin/kill -TERM "$run_pid" 2>/dev/null || true
    /bin/kill -TERM "-$run_pid" 2>/dev/null || true
    if ! host_pids="$(owned_host_processes)"; then
        /bin/kill -KILL "$run_pid" 2>/dev/null || true
        /bin/kill -KILL "-$run_pid" 2>/dev/null || true
        return 1
    fi
    while IFS= read -r host_pid; do
        if [[ "$host_pid" =~ ^[0-9]+$ ]]; then
            /bin/kill -TERM "$host_pid" 2>/dev/null || true
        fi
    done <<< "$host_pids"
    for _ in $(/usr/bin/seq 1 50); do
        group_alive=0
        root_alive=0
        if /bin/kill -0 "$run_pid" 2>/dev/null; then
            if ! root_state="$(
                /bin/ps -o state= -p "$run_pid" |
                    /usr/bin/awk 'NR == 1 { gsub(/[[:space:]]/, ""); print; valid=1 } END { if (!valid) exit 1 }'
            )"; then
                return 1
            fi
            if [[ "$root_state" != Z* ]]; then
                root_alive=1
            fi
        fi
        if ! group_alive="$(process_group_live_state "$run_pid")"; then
            return 1
        fi
        if ! host_pids="$(owned_host_processes)"; then
            /bin/kill -KILL "$run_pid" 2>/dev/null || true
            /bin/kill -KILL "-$run_pid" 2>/dev/null || true
            return 1
        fi
        if [[ "$root_alive" == "0" && "$group_alive" == "0" &&
            -z "$host_pids" ]]; then
            return 0
        fi
        /bin/sleep 0.1
    done
    /bin/kill -KILL "$run_pid" 2>/dev/null || true
    /bin/kill -KILL "-$run_pid" 2>/dev/null || true
    while IFS= read -r host_pid; do
        if [[ "$host_pid" =~ ^[0-9]+$ ]]; then
            /bin/kill -KILL "$host_pid" 2>/dev/null || true
        fi
    done <<< "$host_pids"
    for _ in $(/usr/bin/seq 1 50); do
        group_alive=0
        root_alive=0
        if /bin/kill -0 "$run_pid" 2>/dev/null; then
            if ! root_state="$(
                /bin/ps -o state= -p "$run_pid" |
                    /usr/bin/awk 'NR == 1 { gsub(/[[:space:]]/, ""); print; valid=1 } END { if (!valid) exit 1 }'
            )"; then
                return 1
            fi
            if [[ "$root_state" != Z* ]]; then
                root_alive=1
            fi
        fi
        if ! group_alive="$(process_group_live_state "$run_pid")"; then
            return 1
        fi
        if ! host_pids="$(owned_host_processes)"; then
            return 1
        fi
        if [[ "$root_alive" == "0" && "$group_alive" == "0" &&
            -z "$host_pids" ]]; then
            return 0
        fi
        /bin/sleep 0.1
    done
    return 1
}

process_tree_pids() {
    local root_pid="$1"

    /bin/ps -axo pid=,ppid= | /usr/bin/awk -v root_pid="$root_pid" '
    {
        parent[$1]=$2
    }
    function descends(candidate, current, steps) {
        current=candidate
        for (steps=0; steps<4096 && current!=0; steps++) {
            if (current==root_pid) return 1
            if (!(current in parent) || parent[current]==current) return 0
            current=parent[current]
        }
        return 0
    }
    END {
        for (pid in parent) if (pid!=root_pid && descends(pid)) print pid
    }'
}

terminate_monitor_tree() {
    local child_pid
    local children

    if [[ -z "$monitor_pid" || ! "$monitor_pid" =~ ^[0-9]+$ ]]; then
        return 0
    fi
    if ! children="$(process_tree_pids "$monitor_pid")"; then
        /bin/kill -KILL "$monitor_pid" 2>/dev/null || true
        return 1
    fi
    while IFS= read -r child_pid; do
        if [[ "$child_pid" =~ ^[0-9]+$ ]]; then
            /bin/kill -TERM "$child_pid" 2>/dev/null || true
        fi
    done <<< "$children"
    /bin/kill -TERM "$monitor_pid" 2>/dev/null || true
    for _ in $(/usr/bin/seq 1 20); do
        if ! /bin/kill -0 "$monitor_pid" 2>/dev/null; then
            return 0
        fi
        /bin/sleep 0.05
    done
    if ! children="$(process_tree_pids "$monitor_pid")"; then
        /bin/kill -KILL "$monitor_pid" 2>/dev/null || true
        return 1
    fi
    while IFS= read -r child_pid; do
        if [[ "$child_pid" =~ ^[0-9]+$ ]]; then
            /bin/kill -KILL "$child_pid" 2>/dev/null || true
        fi
    done <<< "$children"
    /bin/kill -KILL "$monitor_pid" 2>/dev/null || true
    for _ in $(/usr/bin/seq 1 20); do
        if ! /bin/kill -0 "$monitor_pid" 2>/dev/null; then
            return 0
        fi
        monitor_state="$(
            /bin/ps -o state= -p "$monitor_pid" 2>/dev/null |
                /usr/bin/awk 'NR == 1 { gsub(/[[:space:]]/, ""); print }'
        )"
        if [[ "$monitor_state" == Z* ]]; then
            return 0
        fi
        /bin/sleep 0.05
    done
    return 1
}

wait_monitor_bounded() {
    local started_seconds=$SECONDS
    local state
    local wait_status

    if [[ -z "$monitor_pid" || ! "$monitor_pid" =~ ^[0-9]+$ ]]; then
        return 2
    fi
    while /bin/kill -0 "$monitor_pid" 2>/dev/null; do
        if ! state="$(
            /bin/ps -o state= -p "$monitor_pid" |
                /usr/bin/awk 'NR == 1 { gsub(/[[:space:]]/, ""); print; valid=1 } END { if (!valid) exit 1 }'
        )"; then
            if /bin/kill -0 "$monitor_pid" 2>/dev/null; then
                terminate_monitor_tree || true
                return 124
            fi
            break
        fi
        if [[ "$state" == Z* ]]; then
            break
        fi
        if (( SECONDS - started_seconds >= 5 )); then
            terminate_monitor_tree || true
            if /bin/kill -0 "$monitor_pid" 2>/dev/null; then
                state="$(
                    /bin/ps -o state= -p "$monitor_pid" 2>/dev/null |
                        /usr/bin/awk 'NR == 1 { gsub(/[[:space:]]/, ""); print }'
                )"
                if [[ "$state" != Z* ]]; then
                    return 124
                fi
            fi
            break
        fi
        /bin/sleep 0.05
    done
    if wait "$monitor_pid"; then
        wait_status=0
    else
        wait_status=$?
    fi
    return "$wait_status"
}

handle_signal() {
    local signal_status="$1"

    exit "$signal_status"
}

handle_exit() {
    local exit_status=$?

    trap - EXIT HUP INT TERM
    set +e
    if ! terminate_run_tree; then
        echo "could not fully terminate the F2 runner tree" >&2
        if [[ "$exit_status" == "0" ]]; then
            exit_status=9
        fi
    fi
    if control_directory_is_exact; then
        : > "$done_signal" 2>/dev/null
    fi
    if [[ -n "$monitor_pid" && "$monitor_pid" =~ ^[0-9]+$ ]]; then
        if ! wait_monitor_bounded; then
            echo "could not stop the F2 competition monitor cleanly" >&2
            if [[ "$exit_status" == "0" ]]; then
                exit_status=9
            fi
        fi
        monitor_pid=""
    fi
    if ! cleanup_control_directory && [[ "$exit_status" == "0" ]]; then
        exit_status=9
    fi
    exit "$exit_status"
}

trap handle_exit EXIT
trap 'handle_signal 129' HUP
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

capture_boundary() {
    local phase="$1"
    local capture_path="$2"
    local digest_path="$3"
    local process_lines
    local process_count
    local current_commit
    local captured_utc
    local worktree_status
    local source_state="dirty"
    local thermal_output
    local thermal_state="warning"
    local power_output
    local power_state="non-AC"
    local load_average

    if ! process_lines="$(matching_processes 0)"; then
        echo "$phase boundary rejected: process inspection failed" >&2
        return 1
    fi
    if ! process_count="$(
        printf '%s\n' "$process_lines" |
            /usr/bin/awk 'NF { count++ } END { print count + 0 }'
    )"; then
        echo "$phase boundary rejected: process count failed" >&2
        return 1
    fi
    if ! current_commit="$(trusted_git -C "$source_root" rev-parse HEAD)"; then
        echo "$phase boundary rejected: source commit inspection failed" >&2
        return 1
    fi
    if ! worktree_status="$(
        trusted_git -C "$source_root" \
            status --porcelain=v1 --untracked-files=all
    )"; then
        echo "$phase boundary rejected: source status inspection failed" >&2
        return 1
    fi
    if [[ "$current_commit" == "$source_commit" && -z "$worktree_status" ]]; then
        source_state="clean"
    fi

    if ! thermal_output="$(/usr/bin/pmset -g therm)"; then
        echo "$phase boundary rejected: thermal inspection failed" >&2
        return 1
    fi
    if printf '%s\n' "$thermal_output" |
        /usr/bin/grep -Fq 'No thermal warning level has been recorded' &&
        printf '%s\n' "$thermal_output" |
            /usr/bin/grep -Fq 'No performance warning level has been recorded'
    then
        thermal_state="none"
    fi
    if ! power_output="$(/usr/bin/pmset -g batt | /usr/bin/head -1)"; then
        echo "$phase boundary rejected: power inspection failed" >&2
        return 1
    fi
    if [[ "$power_output" == *"'AC Power'"* ]]; then
        power_state="AC"
    fi
    if ! load_average="$(/usr/sbin/sysctl -n vm.loadavg | /usr/bin/awk '{print $2}')"; then
        echo "$phase boundary rejected: load inspection failed" >&2
        return 1
    fi
    if ! captured_utc="$(utc_now)"; then
        echo "$phase boundary rejected: timestamp capture failed" >&2
        return 1
    fi

    {
        printf 'format=1\n'
        printf 'phase=%s\n' "$phase"
        printf 'captured_utc=%s\n' "$captured_utc"
        printf 'source_commit=%s\n' "$current_commit"
        printf 'source_status=%s\n' "$source_state"
        printf 'process_filter=%s\n' "$process_filter"
        printf 'competing_process_lines=%s\n' "$process_count"
        printf 'load_average_1m=%s\n' "$load_average"
        printf 'thermal_warning=%s\n' "$thermal_state"
        printf 'power_source=%s\n' "$power_state"
    } > "$capture_path" || return 1
    write_digest "$capture_path" "$digest_path" || return 1
    /bin/chmod a-w "$capture_path" "$digest_path" || return 1

    if [[ "$process_count" != "0" || "$source_state" != "clean" ||
        "$thermal_state" != "none" || "$power_state" != "AC" ]]; then
        echo "$phase boundary rejected: process-count=$process_count source=$source_state thermal=$thermal_state power=$power_state" >&2
        if [[ -n "$process_lines" ]]; then
            printf '%s\n' "$process_lines" >&2
        fi
        return 1
    fi
    return 0
}

artifacts=(
    "$output_prefix.preflight.txt"
    "$output_prefix.preflight.txt.sha256"
    "$output_prefix.xcresult"
    "$output_prefix.log"
    "$output_prefix.log.sha256"
    "$output_prefix.warning-check.txt"
    "$output_prefix.warning-check.txt.sha256"
    "$output_prefix.evidence-manifest.txt"
    "$output_prefix.products"
    "$output_prefix.inspection.xcresult"
    "$output_prefix.outer.log"
    "$output_prefix.outer.log.sha256"
    "$output_prefix.outer.status.txt"
    "$output_prefix.competition-monitor.log"
    "$output_prefix.competition-monitor.log.sha256"
    "$output_prefix.competition-monitor.samples.txt"
    "$output_prefix.competition-monitor.samples.txt.sha256"
    "$output_prefix.run-owned-processes.log"
    "$output_prefix.run-owned-processes.log.sha256"
    "$output_prefix.competition-monitor.status.txt"
    "$output_prefix.competition-monitor.status.txt.sha256"
    "$output_prefix.postflight.txt"
    "$output_prefix.postflight.txt.sha256"
)
for artifact in "${artifacts[@]}"; do
    if [[ -e "$artifact" || -L "$artifact" ]]; then
        echo "refusing to reuse F2 evidence path: $artifact" >&2
        exit 2
    fi
done

actual_commit="$(trusted_git -C "$source_root" rev-parse HEAD)"
actual_status="$(
    trusted_git -C "$source_root" \
        status --porcelain=v1 --untracked-files=all
)"
actual_branch="$(trusted_git -C "$source_root" symbolic-ref -q HEAD || true)"
if [[ "$actual_commit" != "$source_commit" || -n "$actual_status" ||
    -n "$actual_branch" ]]; then
    echo "authoritative F2 source must be the clean detached measured commit" >&2
    exit 2
fi

if ! capture_boundary \
    preflight \
    "$output_prefix.preflight.txt" \
    "$output_prefix.preflight.txt.sha256"; then
    exit 3
fi

control_directory="$(
    /usr/bin/mktemp -d '/private/tmp/plainsong-f2-monitor.XXXXXX'
)"
if [[ "$control_directory" != /private/tmp/plainsong-f2-monitor.* ||
    ! -d "$control_directory" || -L "$control_directory" ||
    "$(/usr/bin/stat -f '%u' "$control_directory")" != "$(/usr/bin/id -u)" ||
    "$(/usr/bin/stat -f '%Lp' "$control_directory")" != "700" ]]; then
    echo "could not allocate an exact monitor control directory" >&2
    exit 4
fi
control_directory_identity="$(/usr/bin/stat -f '%d:%i' "$control_directory")"
done_signal="$control_directory/done"
ready_signal="$control_directory/ready"
runner_pid_record="$control_directory/runner-pid"
runner_finished_record="$control_directory/runner-finished"
runner_finished_sequence_record="$control_directory/runner-finished-sequence"
runner_session_ready="$control_directory/runner-session-ready"
runner_session_go="$control_directory/runner-session-go"
sample_record="$control_directory/sample-count"
first_sample_started_record="$control_directory/first-sample-started"
first_sample_finished_record="$control_directory/first-sample-finished"
last_sample_started_record="$control_directory/last-sample-started"
last_sample_finished_record="$control_directory/last-sample-finished"
: > "$output_prefix.competition-monitor.log"
: > "$output_prefix.competition-monitor.samples.txt"
: > "$output_prefix.run-owned-processes.log"
(
    set -euo pipefail
    sample_count=0
    while true; do
        done_before_sample=0
        if [[ -e "$done_signal" ]]; then
            done_before_sample=1
        fi
        allowed_runner_pid=0
        allow_run_path_correlation=0
        if [[ -e "$runner_finished_record" ]]; then
            if [[ ! -f "$runner_finished_record" || -L "$runner_finished_record" ]]; then
                echo "competition monitor runner-finished record is invalid" >&2
                exit 23
            fi
            if [[ ! -e "$runner_finished_sequence_record" ]]; then
                printf '%s\n' "$((sample_count + 1))" > "$runner_finished_sequence_record"
            fi
        elif [[ -e "$runner_pid_record" ]]; then
            if [[ ! -f "$runner_pid_record" || -L "$runner_pid_record" ]] ||
                ! allowed_runner_pid="$(
                    /usr/bin/awk \
                        'NR == 1 && /^[0-9]+$/ { print; valid=1 } END { if (!valid || NR != 1) exit 1 }' \
                        "$runner_pid_record"
                )"; then
                echo "competition monitor runner PID record is invalid" >&2
                exit 22
            fi
            allow_run_path_correlation=1
        fi
        sample_started="$(utc_now)"
        if ! process_lines="$(
            matching_processes \
                "$allowed_runner_pid" \
                "$allow_run_path_correlation" \
                "$((sample_count + 1))" \
                "$sample_started"
        )"; then
            echo "competition monitor process inspection failed" >&2
            exit 21
        fi
        sample_finished="$(utc_now)"
        sample_count=$((sample_count + 1))
        sample_matches="$(
            printf '%s\n' "$process_lines" |
                /usr/bin/awk 'NF { count++ } END { print count + 0 }'
        )"
        if [[ -n "$process_lines" ]]; then
            printf '%s\n' "$process_lines" >> "$output_prefix.competition-monitor.log"
        fi
        printf 'sequence=%s started_utc=%s finished_utc=%s match_count=%s\n' \
            "$sample_count" \
            "$sample_started" \
            "$sample_finished" \
            "$sample_matches" >> "$output_prefix.competition-monitor.samples.txt"
        printf '%s\n' "$sample_started" > "$last_sample_started_record"
        printf '%s\n' "$sample_finished" > "$last_sample_finished_record"
        if [[ "$sample_count" == "1" ]]; then
            printf '%s\n' "$sample_started" > "$first_sample_started_record"
            printf '%s\n' "$sample_finished" > "$first_sample_finished_record"
            : > "$ready_signal"
        fi
        if [[ "$done_before_sample" == "1" ]]; then
            break
        fi
        /bin/sleep 0.2
    done
    printf '%s\n' "$sample_count" > "$sample_record"
) &
monitor_pid=$!

ready_status=1
for _ in $(/usr/bin/seq 1 500); do
    if [[ -e "$ready_signal" ]]; then
        ready_status=0
        break
    fi
    if ! /bin/kill -0 "$monitor_pid" 2>/dev/null; then
        break
    fi
    /bin/sleep 0.01
done
if [[ "$ready_status" != "0" ]]; then
    : > "$done_signal"
    wait_monitor_bounded || true
    monitor_pid=""
    echo "competition monitor did not complete its first sample" >&2
    exit 5
fi

: > "$output_prefix.outer.log"
/usr/bin/env -i \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_NO_REPLACE_OBJECTS=1 \
    HOME="$runner_home" \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    LOGNAME="$runner_user" \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    TMPDIR="$runner_tmpdir" \
    USER="$runner_user" \
    /usr/bin/python3 -I -c \
    'import os, sys, time
parent_pid = int(sys.argv[1])
if os.getppid() != parent_pid:
    sys.exit(125)
os.setsid()
descriptor = os.open(sys.argv[2], os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o400)
os.write(descriptor, b"ready\n")
os.close(descriptor)
while not os.path.exists(sys.argv[3]):
    if os.getppid() != parent_pid:
        sys.exit(125)
    time.sleep(0.005)
os.execv(sys.argv[4], sys.argv[4:])' \
    "$$" \
    "$runner_session_ready" \
    "$runner_session_go" \
    "$runner" \
    "$configuration" \
    "$derived_data_path" \
    "$output_prefix.xcresult" \
    "$output_prefix.log" >> "$output_prefix.outer.log" 2>&1 &
run_pid=$! run_active=1
runner_session_status=1
for _ in $(/usr/bin/seq 1 500); do
    if [[ -f "$runner_session_ready" && ! -L "$runner_session_ready" ]]; then
        runner_pgid="$(
            /bin/ps -o pgid= -p "$run_pid" 2>/dev/null |
                /usr/bin/awk 'NR == 1 { gsub(/[[:space:]]/, ""); print }'
        )"
        if [[ "$runner_pgid" == "$run_pid" ]]; then
            runner_session_status=0
            break
        fi
    fi
    if ! /bin/kill -0 "$run_pid" 2>/dev/null; then
        break
    fi
    /bin/sleep 0.01
done
if [[ "$runner_session_status" != "0" ]]; then
    termination_failed=1
    terminate_run_tree || true
    echo "F2 runner did not establish its dedicated process group" >&2
    exit 6
fi
printf '%s\n' "$run_pid" > "$runner_pid_record.tmp"
/bin/chmod a-w "$runner_pid_record.tmp"
/bin/mv "$runner_pid_record.tmp" "$runner_pid_record"
: > "$runner_session_go"
run_timed_out=0
run_started_seconds=$SECONDS
while /bin/kill -0 "$run_pid" 2>/dev/null; do
    if ! run_state="$(
        /bin/ps -o state= -p "$run_pid" |
            /usr/bin/awk 'NR == 1 { gsub(/[[:space:]]/, ""); print; valid=1 } END { if (!valid) exit 1 }'
    )"; then
        if /bin/kill -0 "$run_pid" 2>/dev/null; then
            run_timed_out=1
            if ! terminate_run_tree; then
                termination_failed=1
            fi
        fi
        break
    fi
    if [[ "$run_state" == Z* ]]; then
        break
    fi
    if (( SECONDS - run_started_seconds >= run_timeout_seconds )); then
        run_timed_out=1
        if ! terminate_run_tree; then
            termination_failed=1
        fi
        break
    fi
    /bin/sleep 0.2
done
if wait "$run_pid"; then
    wrapper_status=0
else
    wrapper_status=$?
fi
recorded_run_pid="$run_pid"
printf 'finished\n' > "$runner_finished_record"
/bin/chmod a-w "$runner_finished_record"
capture_status=0
if [[ ! -f "$output_prefix.outer.log" ]]; then
    capture_status=1
fi

: > "$done_signal"
if wait_monitor_bounded; then
    monitor_status=0
else
    monitor_status=$?
fi
recorded_monitor_pid="$monitor_pid"
monitor_pid=""
remaining_inspection_failed=0
if ! remaining_host_pids="$(owned_host_processes)"; then
    termination_failed=1
    remaining_inspection_failed=1
    remaining_host_pids=""
fi
remaining_group=0
if ! remaining_group="$(process_group_live_state "$run_pid")"; then
    termination_failed=1
    remaining_inspection_failed=1
    remaining_group=0
fi
if [[ "$remaining_group" != "0" || -n "$remaining_host_pids" ||
    "$remaining_inspection_failed" != "0" ]]; then
    termination_failed=1
    if ! terminate_run_tree; then
        termination_failed=1
    fi
fi
run_active=0
run_pid=""
sample_count="$(
    /usr/bin/awk \
        'NR == 1 && /^[0-9]+$/ { print; valid=1 } END { if (!valid) exit 1 }' \
        "$sample_record"
)"
monitor_started="$(/usr/bin/awk 'NR == 1 { print; valid=1 } END { if (!valid) exit 1 }' "$first_sample_started_record")"
first_sample_finished="$(/usr/bin/awk 'NR == 1 { print; valid=1 } END { if (!valid) exit 1 }' "$first_sample_finished_record")"
last_sample_started="$(/usr/bin/awk 'NR == 1 { print; valid=1 } END { if (!valid) exit 1 }' "$last_sample_started_record")"
monitor_finished="$(/usr/bin/awk 'NR == 1 { print; valid=1 } END { if (!valid) exit 1 }' "$last_sample_finished_record")"
match_count="$(
    /usr/bin/awk \
        'NF { count++ } END { print count + 0 }' \
        "$output_prefix.competition-monitor.log"
)"
run_owned_process_records="$(
    /usr/bin/awk \
        'NF { count++ } END { print count + 0 }' \
        "$output_prefix.run-owned-processes.log"
)"
runner_finished_before_sequence="$(
    /usr/bin/awk \
        'NR == 1 && /^[0-9]+$/ { print; valid=1 } END { if (!valid || NR != 1) exit 1 }' \
        "$runner_finished_sequence_record"
)"

{
    printf 'format=4\n'
    printf 'monitor_pid=%s\n' "$recorded_monitor_pid"
    printf 'runner_pid=%s\n' "$recorded_run_pid"
    printf 'started_utc=%s\n' "$monitor_started"
    printf 'finished_utc=%s\n' "$monitor_finished"
    printf 'first_sample_finished_utc=%s\n' "$first_sample_finished"
    printf 'last_sample_started_utc=%s\n' "$last_sample_started"
    printf 'sample_interval_ms=200\n'
    printf 'sample_count=%s\n' "$sample_count"
    printf 'match_count=%s\n' "$match_count"
    printf 'run_owned_process_records=%s\n' "$run_owned_process_records"
    printf 'runner_finished_before_sequence=%s\n' "$runner_finished_before_sequence"
    printf 'process_filter=%s\n' "$process_filter"
    printf 'process_ownership_rule=%s\n' "$process_ownership_rule"
    printf 'correlation_output_prefix=%s\n' "$output_prefix"
    printf 'allowed_host_executable=%s\n' "$allowed_host_executable"
    printf 'allowed_run_prefix=%s\n' "$output_prefix"
    printf 'exit_status=%s\n' "$monitor_status"
} > "$output_prefix.competition-monitor.status.txt"
{
    printf 'format=3\n'
    printf 'wrapper_exit_status=%s\n' "$wrapper_status"
    printf 'capture_exit_status=%s\n' "$capture_status"
    printf 'run_timeout_seconds=%s\n' "$run_timeout_seconds"
    printf 'timed_out=%s\n' "$run_timed_out"
    printf 'termination_failed=%s\n' "$termination_failed"
    printf 'runner_environment_policy=%s\n' "$runner_environment_policy"
} > "$output_prefix.outer.status.txt"

write_digest \
    "$output_prefix.competition-monitor.log" \
    "$output_prefix.competition-monitor.log.sha256"
write_digest \
    "$output_prefix.competition-monitor.samples.txt" \
    "$output_prefix.competition-monitor.samples.txt.sha256"
write_digest \
    "$output_prefix.run-owned-processes.log" \
    "$output_prefix.run-owned-processes.log.sha256"
write_digest \
    "$output_prefix.competition-monitor.status.txt" \
    "$output_prefix.competition-monitor.status.txt.sha256"
write_digest \
    "$output_prefix.outer.log" \
    "$output_prefix.outer.log.sha256"
/bin/chmod a-w \
    "$output_prefix.competition-monitor.log" \
    "$output_prefix.competition-monitor.log.sha256" \
    "$output_prefix.competition-monitor.samples.txt" \
    "$output_prefix.competition-monitor.samples.txt.sha256" \
    "$output_prefix.run-owned-processes.log" \
    "$output_prefix.run-owned-processes.log.sha256" \
    "$output_prefix.competition-monitor.status.txt" \
    "$output_prefix.competition-monitor.status.txt.sha256" \
    "$output_prefix.outer.log" \
    "$output_prefix.outer.log.sha256" \
    "$output_prefix.outer.status.txt"

postflight_status=0
if ! capture_boundary \
    postflight \
    "$output_prefix.postflight.txt" \
    "$output_prefix.postflight.txt.sha256"; then
    postflight_status=1
fi

if ! cleanup_control_directory; then
    echo "refusing monitor-control cleanup" >&2
    exit 9
fi

echo "F2 OUTER CAPTURE wrapper-status=$wrapper_status capture-status=$capture_status monitor-status=$monitor_status postflight-status=$postflight_status timed-out=$run_timed_out termination-failed=$termination_failed samples=$sample_count matches=$match_count"
if [[ "$wrapper_status" != "0" ]]; then
    exit "$wrapper_status"
fi
if [[ "$capture_status" != "0" || "$monitor_status" != "0" ||
    "$postflight_status" != "0" || "$run_timed_out" != "0" ||
    "$termination_failed" != "0" || "$match_count" != "0" ]]; then
    exit 8
fi
exit 0
