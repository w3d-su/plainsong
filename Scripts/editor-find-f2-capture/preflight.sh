artifacts=(
    "$output_prefix.preflight.txt"
    "$output_prefix.preflight.txt.sha256"
    "$output_prefix.xcresult"
    "$output_prefix.log"
    "$output_prefix.log.sha256"
    "$output_prefix.warning-check.txt"
    "$output_prefix.warning-check.txt.sha256"
    "$output_prefix.evidence-manifest.txt"
    "$output_prefix.products"
    "$output_prefix.inspection.xcresult"
    "$output_prefix.outer.log"
    "$output_prefix.outer.log.sha256"
    "$output_prefix.outer.status.txt"
    "$output_prefix.competition-monitor.log"
    "$output_prefix.competition-monitor.log.sha256"
    "$output_prefix.competition-monitor.samples.txt"
    "$output_prefix.competition-monitor.samples.txt.sha256"
    "$output_prefix.run-owned-processes.log"
    "$output_prefix.run-owned-processes.log.sha256"
    "$output_prefix.competition-monitor.status.txt"
    "$output_prefix.competition-monitor.status.txt.sha256"
    "$output_prefix.postflight.txt"
    "$output_prefix.postflight.txt.sha256"
)
for artifact in "${artifacts[@]}"; do
    if [[ -e "$artifact" || -L "$artifact" ]]; then
        echo "refusing to reuse F2 evidence path: $artifact" >&2
        exit 2
    fi
done

actual_commit="$(trusted_git -C "$source_root" rev-parse HEAD)"
actual_status="$(
    trusted_git -C "$source_root" \
        status --porcelain=v1 --untracked-files=all
)"
actual_branch="$(trusted_git -C "$source_root" symbolic-ref -q HEAD || true)"
if [[ "$actual_commit" != "$source_commit" || -n "$actual_status" ||
    -n "$actual_branch" ]]; then
    echo "authoritative F2 source must be the clean detached measured commit" >&2
    exit 2
fi

if ! capture_boundary \
    preflight \
    "$output_prefix.preflight.txt" \
    "$output_prefix.preflight.txt.sha256"; then
    exit 3
fi

control_directory="$(
    /usr/bin/mktemp -d '/private/tmp/plainsong-f2-monitor.XXXXXX'
)"
if [[ "$control_directory" != /private/tmp/plainsong-f2-monitor.* ||
    ! -d "$control_directory" || -L "$control_directory" ||
    "$(/usr/bin/stat -f '%u' "$control_directory")" != "$(/usr/bin/id -u)" ||
    "$(/usr/bin/stat -f '%Lp' "$control_directory")" != "700" ]]; then
    echo "could not allocate an exact monitor control directory" >&2
    exit 4
fi
control_directory_identity="$(/usr/bin/stat -f '%d:%i' "$control_directory")"
done_signal="$control_directory/done"
ready_signal="$control_directory/ready"
runner_pid_record="$control_directory/runner-pid"
runner_finished_record="$control_directory/runner-finished"
runner_finished_sequence_record="$control_directory/runner-finished-sequence"
runner_session_ready="$control_directory/runner-session-ready"
runner_session_go="$control_directory/runner-session-go"
sample_record="$control_directory/sample-count"
first_sample_started_record="$control_directory/first-sample-started"
first_sample_finished_record="$control_directory/first-sample-finished"
last_sample_started_record="$control_directory/last-sample-started"
last_sample_finished_record="$control_directory/last-sample-finished"
: > "$output_prefix.competition-monitor.log"
: > "$output_prefix.competition-monitor.samples.txt"
: > "$output_prefix.run-owned-processes.log"
