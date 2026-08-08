#!/bin/bash

# Input format is the output of: ps -ww -axo pid=,ppid=,pgid=,comm=
# A reparented process remains launch-correlated only while it stays in the
# runner's dedicated process group. Exactly one frozen product host may be
# correlated in any snapshot; an extra same-path host is a competitor.
f2_classify_process_snapshot() {
    local runner_pid="$1"
    local allowed_host="$2"

    [[ "$runner_pid" =~ ^[0-9]+$ ]] || return 2
    /usr/bin/awk \
        -v runner_pid="$runner_pid" \
        -v allowed_host="$allowed_host" '
    function belongs_to_launch(candidate) {
        return runner_pid != 0 && process_group[candidate] == runner_pid
    }
    {
        pid = $1
        ppid = $2
        pgid = $3
        process_group[pid] = pgid
        executable = $0
        sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]+/, "", executable)
        count = split(executable, components, "/")
        name = components[count]
        if (name ~ /^(xcodebuild|swift-frontend|swiftc|swift-driver|xctest|Plainsong|PlainsongUITests-Runner)$/) {
            tracked[pid] = pid " " ppid " " executable
            path[pid] = executable
        }
    }
    END {
        correlated_host_count = 0
        for (pid in tracked) {
            if (path[pid] == allowed_host && belongs_to_launch(pid)) {
                correlated_host_count++
            }
        }
        for (pid in tracked) {
            if (path[pid] == allowed_host) {
                if (belongs_to_launch(pid) && correlated_host_count == 1) continue
                print tracked[pid]
                continue
            }
            if (belongs_to_launch(pid)) continue
            print tracked[pid]
        }
    }' | /usr/bin/sort -n
}

f2_competitor_processes() {
    local runner_pid="$1"

    /bin/ps -ww -axo pid=,ppid=,pgid=,comm= |
        f2_classify_process_snapshot \
            "$runner_pid" \
            "$F2_ALLOWED_HOST_EXECUTABLE"
}

f2_terminate_run_tree() {
    local runner_pid="$1"
    local signal="${2:-TERM}"

    [[ "$runner_pid" =~ ^[0-9]+$ && "$runner_pid" != 0 ]] || return 2
    /bin/kill -"$signal" "-$runner_pid" 2>/dev/null || true
    /bin/kill -"$signal" "$runner_pid" 2>/dev/null || true
}

f2_wait_run_tree_gone() {
    local runner_pid="$1"
    local state

    for _ in $(/usr/bin/seq 1 50); do
        state="$(/bin/ps -o state= -p "$runner_pid" 2>/dev/null | /usr/bin/awk 'NR==1 {gsub(/[[:space:]]/, ""); print}')"
        if [[ -z "$state" || "$state" == Z* ]]; then
            if ! /bin/kill -0 "-$runner_pid" 2>/dev/null; then
                return 0
            fi
        fi
        /bin/sleep 0.1
    done
    f2_terminate_run_tree "$runner_pid" KILL
    for _ in $(/usr/bin/seq 1 50); do
        state="$(/bin/ps -o state= -p "$runner_pid" 2>/dev/null | /usr/bin/awk 'NR==1 {gsub(/[[:space:]]/, ""); print}')"
        if [[ -z "$state" || "$state" == Z* ]]; then
            if ! /bin/kill -0 "-$runner_pid" 2>/dev/null; then
                return 0
            fi
        fi
        /bin/sleep 0.1
    done
    return 1
}
