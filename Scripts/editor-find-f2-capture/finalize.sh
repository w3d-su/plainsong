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
