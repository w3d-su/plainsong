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

f2_runner_group_identity_is_owned() {
    local runner_pid="$1"
    local identity

    [[ "${F2_RUNNER_REAPED:-1}" == 0 &&
        "$runner_pid" =~ ^[0-9]+$ && "$runner_pid" != 0 ]] || return 1
    identity="$(
        /bin/ps -o pid=,pgid= -p "$runner_pid" 2>/dev/null |
            /usr/bin/awk 'NR == 1 {print $1 " " $2}'
    )" || return 1
    [[ "$identity" == "$runner_pid $runner_pid" ]]
}

# The session leader deliberately remains alive until the capture shell writes
# session-drain. That makes the process-group ID non-reusable while cleanup can
# still signal it. Once the leader is reaped, F2_RUNNER_REAPED permanently
# disables this signal path.
f2_terminate_run_tree() {
    local runner_pid="$1"
    local signal="${2:-TERM}"

    f2_runner_group_identity_is_owned "$runner_pid" || return 2
    /bin/kill -"$signal" "-$runner_pid" 2>/dev/null || true
}

f2_run_group_has_live_member() {
    local runner_pid="$1"

    /bin/ps -ww -axo pid=,pgid=,state= |
        /usr/bin/awk -v runner_pid="$runner_pid" '
            $2 == runner_pid && $1 != runner_pid && $3 !~ /^Z/ { found=1 }
            END { exit(found ? 0 : 1) }
        '
}

f2_wait_run_group_members_gone() {
    local runner_pid="$1"
    local attempts="${2:-50}"

    for _ in $(/usr/bin/seq 1 "$attempts"); do
        f2_run_group_has_live_member "$runner_pid" || return 0
        /bin/sleep 0.1
    done
    return 1
}
