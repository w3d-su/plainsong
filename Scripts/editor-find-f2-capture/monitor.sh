#!/bin/bash

f2_monitor_loop() {
    local output_prefix="$1"
    local control_directory="$2"
    local done_signal="$control_directory/done"
    local runner_pid_record="$control_directory/runner-pid"
    local runner_finished_record="$control_directory/runner-finished"
    local ready_signal="$control_directory/ready"
    local sample_count=0
    local runner_pid=0
    local done_before_sample
    local started
    local finished
    local competitors
    local matches

    : > "$output_prefix.competition-monitor.log"
    : > "$output_prefix.competition-monitor.samples.txt"
    while true; do
        done_before_sample=0
        [[ -e "$done_signal" ]] && done_before_sample=1
        started="$(f2_utc_now)"
        runner_pid=0
        if [[ ! -e "$runner_finished_record" && -e "$runner_pid_record" ]]; then
            [[ -f "$runner_pid_record" && ! -L "$runner_pid_record" ]] || return 22
            runner_pid="$(/usr/bin/awk 'NR==1 && /^[0-9]+$/ {print; ok=1} END {if (!ok || NR != 1) exit 1}' "$runner_pid_record")" || return 22
        fi
        competitors="$(f2_competitor_processes "$runner_pid")" || return 21
        finished="$(f2_utc_now)"
        sample_count=$((sample_count + 1))
        matches="$(printf '%s\n' "$competitors" | /usr/bin/awk 'NF {n++} END {print n+0}')"
        [[ -z "$competitors" ]] || printf '%s\n' "$competitors" >> "$output_prefix.competition-monitor.log"
        printf 'sequence=%s started_utc=%s finished_utc=%s match_count=%s\n' \
            "$sample_count" "$started" "$finished" "$matches" >> \
            "$output_prefix.competition-monitor.samples.txt"
        [[ "$sample_count" != 1 ]] || {
            printf '%s\n' "$started" > "$control_directory/first-started"
            printf '%s\n' "$finished" > "$control_directory/first-finished"
            : > "$ready_signal"
        }
        printf '%s\n' "$started" > "$control_directory/last-started"
        printf '%s\n' "$finished" > "$control_directory/last-finished"
        [[ "$done_before_sample" == 0 ]] || break
        /bin/sleep 0.2
    done
    printf '%s\n' "$sample_count" > "$control_directory/sample-count"
}

f2_monitor_supervisor() {
    local output_prefix="$1"
    local control_directory="$2"
    local status

    # The supervisor is the owned identity. TERM is only a bounded graceful
    # request; the supervisor cannot disappear until the parent closes its
    # signal path and publishes monitor-reap, or sends the final KILL.
    trap '' TERM
    set +e
    f2_monitor_loop "$output_prefix" "$control_directory"
    status=$?
    printf '%s\n' "$status" > "$control_directory/monitor-result.tmp"
    /bin/chmod a-w "$control_directory/monitor-result.tmp"
    /bin/mv "$control_directory/monitor-result.tmp" "$control_directory/monitor-complete"
    while [[ ! -e "$control_directory/monitor-reap" ]]; do
        /bin/sleep 0.01
    done
    return "$status"
}

f2_wait_for_file() {
    local path="$1"
    local pid="$2"
    local attempts="${3:-500}"

    for _ in $(/usr/bin/seq 1 "$attempts"); do
        [[ -f "$path" && ! -L "$path" ]] && return 0
        /bin/kill -0 "$pid" 2>/dev/null || return 1
        /bin/sleep 0.01
    done
    return 1
}

f2_monitor_process_state() {
    local monitor_pid="$1"
    local output

    output="$(/bin/ps -o state= -p "$monitor_pid" 2>/dev/null)" || return 2
    output="$(printf '%s\n' "$output" | /usr/bin/awk 'NR==1 {gsub(/[[:space:]]/, ""); print; found=1} END {if (!found || NR != 1) exit 1}')" || return 2
    [[ "$output" =~ ^[A-Za-z][A-Za-z+\<]*$ ]] || return 2
    printf '%s\n' "$output"
}

f2_monitor_identity_is_signalable() {
    local monitor_pid="$1"
    local state

    [[ "$F2_ACTIVE_MONITOR_PID" == "$monitor_pid" &&
        "${F2_MONITOR_LIFECYCLE:-cleared}" == signalable &&
        "$monitor_pid" =~ ^[0-9]+$ && "$monitor_pid" != 0 ]] || return 1
    f2_monitor_job_is_owned "$monitor_pid" || return 1
    state="$(f2_monitor_process_state "$monitor_pid")" || return 2
    [[ "$state" != Z* ]]
}

f2_monitor_job_is_owned() {
    local monitor_pid="$1"
    local job_pid
    local job_pids

    job_pids="$(builtin jobs -p)"
    while IFS= read -r job_pid; do
        [[ "$job_pid" == "$monitor_pid" ]] && return 0
    done <<< "$job_pids"
    return 1
}

f2_monitor_enter_reap_only() {
    local monitor_pid="$1"

    [[ "$F2_ACTIVE_MONITOR_PID" == "$monitor_pid" &&
        "${F2_MONITOR_LIFECYCLE:-cleared}" == signalable ]] || return 2
    f2_monitor_job_is_owned "$monitor_pid" || return 2
    F2_MONITOR_LIFECYCLE=reap-only
}

f2_clear_monitor() {
    F2_MONITOR_LIFECYCLE=cleared
    F2_ACTIVE_MONITOR_PID=""
}

f2_wait_monitor() {
    local monitor_pid="$1"
    local started=$SECONDS
    local status
    local state_status
    local result_path="$F2_CONTROL_DIRECTORY/monitor-complete"

    while [[ ! -f "$result_path" ]]; do
        if f2_monitor_identity_is_signalable "$monitor_pid" >/dev/null; then
            state_status=0
        else
            state_status=$?
            f2_stop_monitor "$monitor_pid" || return 125
            [[ "$state_status" == 2 ]] && return 126
            return 125
        fi
        if (( SECONDS - started >= 5 )); then
            f2_stop_monitor "$monitor_pid" || return 125
            return 124
        fi
        /bin/sleep 0.05
    done
    status="$(/usr/bin/awk 'NR==1 && /^[0-9]+$/ {print; ok=1} END {if (!ok || NR != 1) exit 1}' "$result_path")" || {
        f2_stop_monitor "$monitor_pid" || true
        return 125
    }
    f2_monitor_enter_reap_only "$monitor_pid" || return 125
    : > "$F2_CONTROL_DIRECTORY/monitor-reap"
    builtin wait "$monitor_pid" 2>/dev/null || true
    f2_clear_monitor
    return "$status"
}

f2_wait_monitor_stopped() {
    local monitor_pid="$1"
    local attempts="${2:-100}"
    local state
    local state_status

    for _ in $(/usr/bin/seq 1 "$attempts"); do
        [[ ! -f "$F2_CONTROL_DIRECTORY/monitor-complete" ]] || return 0
        if state="$(f2_monitor_process_state "$monitor_pid")"; then
            [[ "$state" != Z* ]] || return 2
        else
            state_status=$?
            [[ "$state_status" == 2 ]] && return 2
            return 2
        fi
        /bin/sleep 0.05
    done
    return 1
}

f2_stop_monitor() {
    local monitor_pid="$1"
    local attempts="${2:-100}"
    local inspection_failed=0

    [[ "$F2_ACTIVE_MONITOR_PID" == "$monitor_pid" &&
        "${F2_MONITOR_LIFECYCLE:-cleared}" == signalable &&
        "$monitor_pid" =~ ^[0-9]+$ && "$monitor_pid" != 0 ]] || return 2
    f2_monitor_job_is_owned "$monitor_pid" || return 2
    if f2_monitor_process_state "$monitor_pid" >/dev/null; then
        /bin/kill -TERM "$monitor_pid" 2>/dev/null || true
    else
        inspection_failed=1
    fi
    if f2_wait_monitor_stopped "$monitor_pid" "$attempts"; then
        f2_monitor_enter_reap_only "$monitor_pid" || return 1
        : > "$F2_CONTROL_DIRECTORY/monitor-reap"
    else
        # The supervised monitor ignores TERM. Inspection failure is not
        # treated as stopped; close the signal path before the final KILL.
        f2_monitor_job_is_owned "$monitor_pid" || return 1
        F2_MONITOR_LIFECYCLE=reap-only
        /bin/kill -KILL "$monitor_pid" 2>/dev/null || true
    fi
    builtin wait "$monitor_pid" 2>/dev/null || true
    f2_clear_monitor
    [[ "$inspection_failed" == 0 ]]
}

f2_reap_monitor_only() {
    local monitor_pid="$1"

    [[ "$F2_ACTIVE_MONITOR_PID" == "$monitor_pid" &&
        "$F2_MONITOR_LIFECYCLE" == reap-only ]] || return 2
    [[ -e "$F2_CONTROL_DIRECTORY/monitor-reap" ]] ||
        : > "$F2_CONTROL_DIRECTORY/monitor-reap"
    builtin wait "$monitor_pid" 2>/dev/null || true
    f2_clear_monitor
}

f2_write_monitor_status() {
    local output_prefix="$1"
    local control_directory="$2"
    local monitor_pid="$3"
    local runner_pid="$4"
    local exit_status="$5"
    local sample_count
    local match_count

    sample_count="$(/usr/bin/awk 'NR==1 && /^[0-9]+$/ {print; ok=1} END {if (!ok || NR != 1) exit 1}' "$control_directory/sample-count")" || return
    match_count="$(/usr/bin/awk 'NF {n++} END {print n+0}' "$output_prefix.competition-monitor.log")" || return
    {
        printf 'format=%s\n' "$F2_MONITOR_FORMAT"
        printf 'monitor_pid=%s\n' "$monitor_pid"
        printf 'runner_pid=%s\n' "$runner_pid"
        printf 'started_utc=%s\n' "$(<"$control_directory/first-started")"
        printf 'finished_utc=%s\n' "$(<"$control_directory/last-finished")"
        printf 'first_sample_finished_utc=%s\n' "$(<"$control_directory/first-finished")"
        printf 'last_sample_started_utc=%s\n' "$(<"$control_directory/last-started")"
        printf 'sample_interval_ms=%s\n' "$F2_MONITOR_INTERVAL_MS"
        printf 'sample_count=%s\n' "$sample_count"
        printf 'match_count=%s\n' "$match_count"
        printf 'process_filter=%s\n' "$F2_PROCESS_FILTER"
        printf 'process_ownership_rule=%s\n' "$F2_PROCESS_OWNERSHIP_RULE"
        printf 'capture_tooling_sha256=%s\n' "$F2_CAPTURE_TOOLING_SHA256"
        printf 'allowed_host_executable=%s\n' "$F2_ALLOWED_HOST_EXECUTABLE"
        printf 'exit_status=%s\n' "$exit_status"
    } > "$output_prefix.competition-monitor.status.txt"
    f2_write_digest \
        "$output_prefix.competition-monitor.log" \
        "$output_prefix.competition-monitor.log.sha256"
    f2_write_digest \
        "$output_prefix.competition-monitor.samples.txt" \
        "$output_prefix.competition-monitor.samples.txt.sha256"
    f2_write_digest \
        "$output_prefix.competition-monitor.status.txt" \
        "$output_prefix.competition-monitor.status.txt.sha256"
}
