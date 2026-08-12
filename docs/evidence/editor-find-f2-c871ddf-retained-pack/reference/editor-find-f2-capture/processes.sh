#!/bin/bash

# Input format is the output of: ps -ww -axo pid=,ppid=,comm=
# The only non-descendant exception is the exact frozen product executable.
f2_classify_process_snapshot() {
    local runner_pid="$1"
    local allow_exact_host="$2"
    local allowed_host="$3"

    [[ "$runner_pid" =~ ^[0-9]+$ &&
        ("$allow_exact_host" == 0 || "$allow_exact_host" == 1) ]] || return 2
    /usr/bin/awk \
        -v runner_pid="$runner_pid" \
        -v allow_exact_host="$allow_exact_host" \
        -v allowed_host="$allowed_host" '
    function belongs_to_runner(candidate, current, steps) {
        if (runner_pid == 0) return 0
        current = candidate
        for (steps = 0; steps < 4096 && current != 0; steps++) {
            if (current == runner_pid) return 1
            if (!(current in parent) || parent[current] == current) return 0
            current = parent[current]
        }
        return 0
    }
    {
        pid = $1
        ppid = $2
        parent[pid] = ppid
        executable = $0
        sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+/, "", executable)
        count = split(executable, components, "/")
        name = components[count]
        if (name ~ /^(xcodebuild|swift-frontend|swiftc|swift-driver|xctest|Plainsong|PlainsongUITests-Runner)$/) {
            tracked[pid] = pid " " ppid " " executable
            path[pid] = executable
        }
    }
    END {
        for (pid in tracked) {
            if (belongs_to_runner(pid)) continue
            if (allow_exact_host == 1 && path[pid] == allowed_host) continue
            print tracked[pid]
        }
    }' | /usr/bin/sort -n
}

f2_competitor_processes() {
    local runner_pid="$1"
    local allow_exact_host="$2"

    /bin/ps -ww -axo pid=,ppid=,comm= |
        f2_classify_process_snapshot \
            "$runner_pid" \
            "$allow_exact_host" \
            "$F2_ALLOWED_HOST_EXECUTABLE"
}

f2_exact_host_pids() {
    /bin/ps -ww -axo pid=,comm= | /usr/bin/awk \
        -v allowed_host="$F2_ALLOWED_HOST_EXECUTABLE" '
    {
        pid = $1
        executable = $0
        sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", executable)
        if (executable == allowed_host) print pid
    }'
}

f2_process_tree_pids() {
    local root_pid="$1"

    /bin/ps -axo pid=,ppid= | /usr/bin/awk -v root_pid="$root_pid" '
    { parent[$1] = $2 }
    function descends(candidate, current, steps) {
        current = candidate
        for (steps = 0; steps < 4096 && current != 0; steps++) {
            if (current == root_pid) return 1
            if (!(current in parent) || parent[current] == current) return 0
            current = parent[current]
        }
        return 0
    }
    END { for (pid in parent) if (pid != root_pid && descends(pid)) print pid }'
}

f2_terminate_run_tree() {
    local runner_pid="$1"
    local signal="${2:-TERM}"
    local pid

    [[ "$runner_pid" =~ ^[0-9]+$ ]] || return 2
    /bin/kill -"$signal" "$runner_pid" 2>/dev/null || true
    /bin/kill -"$signal" "-$runner_pid" 2>/dev/null || true
    while IFS= read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ ]] && /bin/kill -"$signal" "$pid" 2>/dev/null || true
    done < <(f2_exact_host_pids)
}

f2_wait_run_tree_gone() {
    local runner_pid="$1"
    local pid
    local state

    for _ in $(/usr/bin/seq 1 50); do
        state="$(/bin/ps -o state= -p "$runner_pid" 2>/dev/null | /usr/bin/awk 'NR==1 {gsub(/[[:space:]]/, ""); print}')"
        if [[ -z "$state" || "$state" == Z* ]]; then
            if [[ -z "$(f2_exact_host_pids)" ]] && ! /bin/kill -0 "-$runner_pid" 2>/dev/null; then
                return 0
            fi
        fi
        /bin/sleep 0.1
    done
    f2_terminate_run_tree "$runner_pid" KILL
    for _ in $(/usr/bin/seq 1 50); do
        state="$(/bin/ps -o state= -p "$runner_pid" 2>/dev/null | /usr/bin/awk 'NR==1 {gsub(/[[:space:]]/, ""); print}')"
        if [[ -z "$state" || "$state" == Z* ]]; then
            if [[ -z "$(f2_exact_host_pids)" ]] && ! /bin/kill -0 "-$runner_pid" 2>/dev/null; then
                return 0
            fi
        fi
        /bin/sleep 0.1
    done
    return 1
}
