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
