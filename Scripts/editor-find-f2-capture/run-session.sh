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
