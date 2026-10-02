from __future__ import annotations

import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path


class RunnerDrainTests(unittest.TestCase):
    capture = Path(__file__).resolve().parent.parent / "editor-find-f2-capture"

    def inspect(self, snapshot: str, snapshot_status: int = 0) -> subprocess.CompletedProcess[str]:
        command = f"""
source {shlex.quote(str(self.capture / 'processes.sh'))}
f2_process_table_snapshot() {{ /bin/cat; return {snapshot_status}; }}
f2_run_group_has_live_member 200
exit $?
"""
        return subprocess.run(
            ["/bin/bash", "--noprofile", "--norc", "-c", command],
            input=snapshot,
            capture_output=True,
            text=True,
            check=False,
            timeout=2,
        )

    def test_unrelated_unknown_state_does_not_prevent_owned_group_drain(self) -> None:
        result = self.inspect("200 200 Ss\n201 200 Z\n300 300 ?\n")
        self.assertEqual(result.returncode, 1, result.stderr)

    def test_unrelated_unknown_state_does_not_hide_owned_live_member(self) -> None:
        result = self.inspect("200 200 Ss\n201 200 T\n300 300 ?\n")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_owned_unknown_state_is_inspection_failure_with_rejected_row(self) -> None:
        result = self.inspect("200 200 Ss\n201 200 ?\n")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("201 200 ?", result.stderr)

    def test_malformed_identity_is_inspection_failure_with_rejected_row(self) -> None:
        result = self.inspect("200 200 Ss\ninvalid 300 S\n")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("invalid 300 S", result.stderr)

    def test_empty_snapshot_is_inspection_failure_with_diagnostic(self) -> None:
        result = self.inspect("")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("inspection failed", result.stderr)

    def test_snapshot_command_failure_retains_exit_status(self) -> None:
        result = self.inspect("", snapshot_status=77)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("exit=77", result.stderr)

    def test_forced_cleanup_reaps_but_does_not_report_a_proven_drain(self) -> None:
        for drain_status in (1, 2):
            with self.subTest(drain_status=drain_status), tempfile.TemporaryDirectory(
                prefix="f2-forced-cleanup.", dir="/private/tmp"
            ) as temporary:
                control = Path(temporary)
                command = f"""
source {shlex.quote(str(self.capture / 'processes.sh'))}
source {shlex.quote(str(self.capture / 'monitor.sh'))}
source {shlex.quote(str(self.capture / 'run.sh'))}
F2_CONTROL_DIRECTORY={shlex.quote(str(control))}
trap 'if [[ -n "$F2_ACTIVE_RUNNER_PID" ]]; then
    if [[ "$F2_RUNNER_LIFECYCLE" == signalable ]]; then
        f2_terminate_run_tree "$F2_ACTIVE_RUNNER_PID" KILL
    fi
    builtin wait "$F2_ACTIVE_RUNNER_PID" 2>/dev/null || true
fi' EXIT
/usr/bin/python3 -I {shlex.quote(str(self.capture / 'session_status.py'))} \
    "$F2_CONTROL_DIRECTORY/session-ready" "$F2_CONTROL_DIRECTORY/session-go" \
    "$F2_CONTROL_DIRECTORY/session-status" "$F2_CONTROL_DIRECTORY/session-drain" \
    /bin/sleep 30 &
F2_ACTIVE_RUNNER_PID=$!
F2_RUNNER_LIFECYCLE=signalable
f2_wait_for_file "$F2_CONTROL_DIRECTORY/session-ready" "$F2_ACTIVE_RUNNER_PID" || exit 20
f2_wait_run_group_members_gone() {{ return {drain_status}; }}
if f2_stop_and_reap_runner "$F2_ACTIVE_RUNNER_PID"; then
    cleanup_status=0
else
    cleanup_status=$?
fi
printf 'cleanup_status=%s\nlifecycle=%s\npid=%s\n' \
    "$cleanup_status" "$F2_RUNNER_LIFECYCLE" "$F2_ACTIVE_RUNNER_PID"
[[ ! -e "$F2_CONTROL_DIRECTORY/session-drain" ]] || exit 21
"""
                result = subprocess.run(
                    ["/bin/bash", "--noprofile", "--norc", "-c", command],
                    capture_output=True,
                    text=True,
                    check=False,
                    timeout=3,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    result.stdout,
                    f"cleanup_status={drain_status}\nlifecycle=cleared\npid=\n",
                    result.stderr,
                )
                self.assertIn(f"drain_status={drain_status}", result.stderr)
