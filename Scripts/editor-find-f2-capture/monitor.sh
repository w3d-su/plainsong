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

f2_wait_monitor() {
    local monitor_pid="$1"
    local started=$SECONDS
    local state

    while /bin/kill -0 "$monitor_pid" 2>/dev/null; do
        state="$(/bin/ps -o state= -p "$monitor_pid" 2>/dev/null | /usr/bin/awk 'NR==1 {gsub(/[[:space:]]/, ""); print}')"
        [[ "$state" != Z* ]] || break
        if (( SECONDS - started >= 5 )); then
            /bin/kill -TERM "$monitor_pid" 2>/dev/null || true
            return 124
        fi
        /bin/sleep 0.05
    done
    wait "$monitor_pid"
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
