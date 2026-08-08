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
