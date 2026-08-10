#!/bin/bash

F2_CONTROL_DIRECTORY=""
F2_CONTROL_IDENTITY=""
F2_ACTIVE_RUNNER_PID=""
F2_ACTIVE_MONITOR_PID=""

f2_control_directory_is_exact() {
    local identity

    [[ -n "$F2_CONTROL_DIRECTORY" &&
        "$F2_CONTROL_DIRECTORY" == /private/tmp/plainsong-f2-monitor.* &&
        -d "$F2_CONTROL_DIRECTORY" && ! -L "$F2_CONTROL_DIRECTORY" ]] || return 1
    identity="$(/usr/bin/stat -f '%d:%i' "$F2_CONTROL_DIRECTORY")" || return
    [[ "$identity" == "$F2_CONTROL_IDENTITY" &&
        "$(/usr/bin/stat -f '%u' "$F2_CONTROL_DIRECTORY")" == "$(/usr/bin/id -u)" &&
        "$(/usr/bin/stat -f '%Lp' "$F2_CONTROL_DIRECTORY")" == 700 ]]
}

f2_cleanup_control_directory() {
    [[ -n "$F2_CONTROL_DIRECTORY" ]] || return 0
    f2_control_directory_is_exact || return 1
    /bin/rm -rf -- "$F2_CONTROL_DIRECTORY" || return
    F2_CONTROL_DIRECTORY=""
    F2_CONTROL_IDENTITY=""
}

f2_capture_exit() {
    local status=$?

    trap - EXIT HUP INT TERM
    set +e
    if [[ "$F2_ACTIVE_RUNNER_PID" =~ ^[0-9]+$ ]]; then
        f2_terminate_run_tree "$F2_ACTIVE_RUNNER_PID" TERM
        f2_wait_run_tree_gone "$F2_ACTIVE_RUNNER_PID" || status=9
    fi
    if f2_control_directory_is_exact; then
        : > "$F2_CONTROL_DIRECTORY/done"
    fi
    if [[ "$F2_ACTIVE_MONITOR_PID" =~ ^[0-9]+$ ]]; then
        /bin/kill -TERM "$F2_ACTIVE_MONITOR_PID" 2>/dev/null || true
        wait "$F2_ACTIVE_MONITOR_PID" 2>/dev/null || true
    fi
    f2_cleanup_control_directory || status=9
    exit "$status"
}

f2_validate_capture_arguments() {
    if [[ "$#" != 4 ]]; then
        f2_die "usage: capture-editor-find-f2-authoritative-run.sh CONFIGURATION SOURCE_ROOT DERIVED_DATA_PATH OUTPUT_PREFIX"
        return 2
    fi
    F2_CONFIGURATION="$1"
    F2_SOURCE_ROOT="$2"
    F2_DERIVED_DATA_PATH="$3"
    F2_OUTPUT_PREFIX="$4"
    if [[ "$F2_CONFIGURATION" != Debug && "$F2_CONFIGURATION" != Release ]]; then
        f2_die "configuration must be Debug or Release"
        return 2
    fi
    f2_require_canonical_directory "$F2_SOURCE_ROOT" "source root" || return
    f2_require_canonical_directory "$F2_DERIVED_DATA_PATH" "DerivedData" || return
    if [[ "$F2_OUTPUT_PREFIX" != /* || "$F2_OUTPUT_PREFIX" == *[[:space:]]* ]]; then
        f2_die "output prefix must be an absolute whitespace-free path"
        return 2
    fi
    local output_directory="${F2_OUTPUT_PREFIX%/*}"
    local output_leaf="${F2_OUTPUT_PREFIX##*/}"
    if [[ -z "$output_leaf" || ! "$output_leaf" =~ ^[A-Za-z0-9._-]+$ ]]; then
        f2_die "output prefix leaf is not simple"
        return 2
    fi
    f2_require_owner_directory "$output_directory" "output directory" || return
    F2_ALLOWED_HOST_EXECUTABLE="$F2_OUTPUT_PREFIX.products/Build/Products/$F2_CONFIGURATION/Plainsong.app/Contents/MacOS/Plainsong"
    F2_RUNNER="$F2_SOURCE_ROOT/Scripts/run-editor-find-f2-performance-gate.sh"
    if [[ ! -x "$F2_RUNNER" ]]; then
        f2_die "exact-source F2 runner is missing"
        return 2
    fi
}

f2_refuse_existing_artifacts() {
    local suffix
    local suffixes=(
        preflight.txt preflight.txt.sha256 xcresult log log.sha256
        warning-check.txt warning-check.txt.sha256 evidence-manifest.txt products
        inspection.xcresult outer.log outer.log.sha256 outer.status.txt
        competition-monitor.log competition-monitor.log.sha256
        competition-monitor.samples.txt competition-monitor.samples.txt.sha256
        competition-monitor.status.txt competition-monitor.status.txt.sha256
        postflight.txt postflight.txt.sha256
    )
    for suffix in "${suffixes[@]}"; do
        [[ ! -e "$F2_OUTPUT_PREFIX.$suffix" && ! -L "$F2_OUTPUT_PREFIX.$suffix" ]] ||
            f2_die "refusing to reuse evidence path: $F2_OUTPUT_PREFIX.$suffix" || return
    done
}

f2_require_exact_source() {
    local commit
    local status
    local branch

    commit="$(f2_trusted_git -C "$F2_SOURCE_ROOT" rev-parse HEAD)" || return
    status="$(f2_trusted_git -C "$F2_SOURCE_ROOT" status --porcelain=v1 --untracked-files=all)" || return
    branch="$(f2_trusted_git -C "$F2_SOURCE_ROOT" symbolic-ref -q HEAD || true)"
    [[ "$commit" == "$F2_SOURCE_COMMIT" && -z "$status" && -z "$branch" ]] ||
        f2_die "source must be the clean detached measured commit"
}

f2_start_runner() {
    local session_ready="$F2_CONTROL_DIRECTORY/session-ready"
    local session_go="$F2_CONTROL_DIRECTORY/session-go"
    local runner_user
    local runner_home
    local pgid

    runner_user="$(/usr/bin/id -un)"
    runner_home="$(/usr/bin/env -i LANG=C LC_ALL=C PATH=/usr/bin:/bin /usr/bin/python3 -I -c 'import os,pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')"
    : > "$F2_OUTPUT_PREFIX.outer.log"
    /usr/bin/env -i \
        GIT_CONFIG_GLOBAL=/dev/null \
        GIT_CONFIG_NOSYSTEM=1 \
        GIT_NO_REPLACE_OBJECTS=1 \
        HOME="$runner_home" \
        LANG=en_US.UTF-8 \
        LC_ALL=en_US.UTF-8 \
        LOGNAME="$runner_user" \
        PATH=/usr/bin:/bin:/usr/sbin:/sbin \
        TMPDIR=/private/tmp \
        USER="$runner_user" \
        /usr/bin/python3 -I -c \
        'import os,sys,time
os.setsid()
fd=os.open(sys.argv[1], os.O_WRONLY|os.O_CREAT|os.O_EXCL, 0o400)
os.write(fd,b"ready\n"); os.close(fd)
while not os.path.exists(sys.argv[2]): time.sleep(0.005)
os.execv(sys.argv[3], sys.argv[3:])' \
        "$session_ready" "$session_go" "$F2_RUNNER" \
        "$F2_CONFIGURATION" "$F2_DERIVED_DATA_PATH" \
        "$F2_OUTPUT_PREFIX.xcresult" "$F2_OUTPUT_PREFIX.log" >> \
        "$F2_OUTPUT_PREFIX.outer.log" 2>&1 &
    F2_ACTIVE_RUNNER_PID=$!
    f2_wait_for_file "$session_ready" "$F2_ACTIVE_RUNNER_PID" || return 1
    pgid="$(/bin/ps -o pgid= -p "$F2_ACTIVE_RUNNER_PID" | /usr/bin/awk 'NR==1 {gsub(/[[:space:]]/, ""); print}')"
    [[ "$pgid" == "$F2_ACTIVE_RUNNER_PID" ]] || return 1
    printf '%s\n' "$F2_ACTIVE_RUNNER_PID" > "$F2_CONTROL_DIRECTORY/runner-pid.tmp"
    /bin/chmod a-w "$F2_CONTROL_DIRECTORY/runner-pid.tmp"
    /bin/mv "$F2_CONTROL_DIRECTORY/runner-pid.tmp" "$F2_CONTROL_DIRECTORY/runner-pid"
    : > "$session_go"
}

f2_wait_runner() {
    local started=$SECONDS
    local state

    F2_TIMED_OUT=0
    while /bin/kill -0 "$F2_ACTIVE_RUNNER_PID" 2>/dev/null; do
        state="$(/bin/ps -o state= -p "$F2_ACTIVE_RUNNER_PID" 2>/dev/null | /usr/bin/awk 'NR==1 {gsub(/[[:space:]]/, ""); print}')"
        [[ "$state" != Z* ]] || break
        if (( SECONDS - started >= F2_RUN_TIMEOUT_SECONDS )); then
            F2_TIMED_OUT=1
            f2_terminate_run_tree "$F2_ACTIVE_RUNNER_PID" TERM
            f2_wait_run_tree_gone "$F2_ACTIVE_RUNNER_PID" || F2_TERMINATION_FAILED=1
            break
        fi
        /bin/sleep 0.2
    done
    if wait "$F2_ACTIVE_RUNNER_PID"; then
        F2_WRAPPER_STATUS=0
    else
        F2_WRAPPER_STATUS=$?
    fi
}

f2_write_outer_status() {
    {
        printf 'format=%s\n' "$F2_OUTER_FORMAT"
        printf 'wrapper_exit_status=%s\n' "$F2_WRAPPER_STATUS"
        printf 'capture_exit_status=%s\n' "$F2_CAPTURE_STATUS"
        printf 'monitor_exit_status=%s\n' "$F2_MONITOR_STATUS"
        printf 'postflight_exit_status=%s\n' "$F2_POSTFLIGHT_STATUS"
        printf 'run_timeout_seconds=%s\n' "$F2_RUN_TIMEOUT_SECONDS"
        printf 'timed_out=%s\n' "$F2_TIMED_OUT"
        printf 'termination_failed=%s\n' "$F2_TERMINATION_FAILED"
        printf 'runner_environment_policy=%s\n' "$F2_RUNNER_ENVIRONMENT_POLICY"
    } > "$F2_OUTPUT_PREFIX.outer.status.txt"
    f2_write_digest "$F2_OUTPUT_PREFIX.outer.log" "$F2_OUTPUT_PREFIX.outer.log.sha256"
}

f2_capture_main() {
    F2_SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && /bin/pwd -P)"
    /usr/bin/umask 077
    f2_validate_capture_arguments "$@" || return
    f2_validate_schema || return
    F2_CAPTURE_TOOLING_SHA256="$(f2_capture_tooling_digest)" || return
    [[ "$F2_CAPTURE_TOOLING_SHA256" =~ ^[0-9a-f]{64}$ ]] || return 2
    f2_refuse_existing_artifacts || return
    f2_require_exact_source || return

    trap f2_capture_exit EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    f2_capture_boundary preflight \
        "$F2_OUTPUT_PREFIX.preflight.txt" \
        "$F2_OUTPUT_PREFIX.preflight.txt.sha256" || return 3

    F2_CONTROL_DIRECTORY="$(/usr/bin/mktemp -d /private/tmp/plainsong-f2-monitor.XXXXXX)"
    F2_CONTROL_IDENTITY="$(/usr/bin/stat -f '%d:%i' "$F2_CONTROL_DIRECTORY")"
    f2_control_directory_is_exact || return 4
    f2_monitor_loop "$F2_OUTPUT_PREFIX" "$F2_CONTROL_DIRECTORY" &
    F2_ACTIVE_MONITOR_PID=$!
    f2_wait_for_file "$F2_CONTROL_DIRECTORY/ready" "$F2_ACTIVE_MONITOR_PID" || return 5
    f2_start_runner || return 6
    local recorded_runner_pid="$F2_ACTIVE_RUNNER_PID"
    local recorded_monitor_pid="$F2_ACTIVE_MONITOR_PID"
    F2_TERMINATION_FAILED=0
    f2_wait_runner
    printf 'finished\n' > "$F2_CONTROL_DIRECTORY/runner-finished"
    /bin/chmod a-w "$F2_CONTROL_DIRECTORY/runner-finished"
    : > "$F2_CONTROL_DIRECTORY/done"
    if f2_wait_monitor "$F2_ACTIVE_MONITOR_PID"; then
        F2_MONITOR_STATUS=0
    else
        F2_MONITOR_STATUS=$?
    fi
    F2_ACTIVE_MONITOR_PID=""
    if ! f2_wait_run_tree_gone "$recorded_runner_pid"; then
        F2_TERMINATION_FAILED=1
    fi
    F2_ACTIVE_RUNNER_PID=""
    [[ -f "$F2_OUTPUT_PREFIX.outer.log" ]] && F2_CAPTURE_STATUS=0 || F2_CAPTURE_STATUS=1
    if f2_capture_boundary postflight \
        "$F2_OUTPUT_PREFIX.postflight.txt" \
        "$F2_OUTPUT_PREFIX.postflight.txt.sha256"; then
        F2_POSTFLIGHT_STATUS=0
    else
        F2_POSTFLIGHT_STATUS=1
    fi
    f2_write_monitor_status "$F2_OUTPUT_PREFIX" "$F2_CONTROL_DIRECTORY" \
        "$recorded_monitor_pid" "$recorded_runner_pid" "$F2_MONITOR_STATUS"
    f2_write_outer_status
    /bin/chmod a-w "$F2_OUTPUT_PREFIX".{competition-monitor.log,competition-monitor.log.sha256,competition-monitor.samples.txt,competition-monitor.samples.txt.sha256,competition-monitor.status.txt,competition-monitor.status.txt.sha256,outer.log,outer.log.sha256,outer.status.txt}
    f2_cleanup_control_directory || return 9
    trap - EXIT HUP INT TERM

    echo "F2 OUTER CAPTURE wrapper-status=$F2_WRAPPER_STATUS capture-status=$F2_CAPTURE_STATUS monitor-status=$F2_MONITOR_STATUS postflight-status=$F2_POSTFLIGHT_STATUS timed-out=$F2_TIMED_OUT termination-failed=$F2_TERMINATION_FAILED"
    [[ "$F2_WRAPPER_STATUS" == 0 ]] || return "$F2_WRAPPER_STATUS"
    [[ "$F2_CAPTURE_STATUS" == 0 && "$F2_MONITOR_STATUS" == 0 &&
        "$F2_POSTFLIGHT_STATUS" == 0 && "$F2_TIMED_OUT" == 0 &&
        "$F2_TERMINATION_FAILED" == 0 &&
        ! -s "$F2_OUTPUT_PREFIX.competition-monitor.log" ]] || return 8
}
