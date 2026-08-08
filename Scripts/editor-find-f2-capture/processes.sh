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
