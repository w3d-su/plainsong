from __future__ import annotations

import os
import shlex
import signal
import subprocess
import unittest
from pathlib import Path


class ProcessOwnershipTests(unittest.TestCase):
    helper = Path(__file__).resolve().parent.parent / "editor-find-f2-capture" / "processes.sh"
    host = "/private/tmp/f2/run.products/Build/Products/Debug/Plainsong.app/Contents/MacOS/Plainsong"

    def classify(self, snapshot: str, runner: int = 200) -> list[str]:
        command = (
            f"source {self.helper!s}; "
            f"f2_classify_process_snapshot {runner} {self.host!s}"
        )
        completed = subprocess.run(
            ["/bin/bash", "--noprofile", "--norc", "-c", command],
            input=snapshot,
            text=True,
            capture_output=True,
            check=True,
        )
        return completed.stdout.splitlines()

    def test_runner_descendants_and_exact_reparented_host_are_allowed(self) -> None:
        snapshot = (
            "200 10 200 /usr/bin/python3\n"
            "201 200 200 /usr/bin/xcodebuild\n"
            "202 201 200 /usr/bin/xctest\n"
            f"300 1 200 {self.host}\n"
        )
        self.assertEqual(self.classify(snapshot), [])

    def test_exact_host_is_competitor_outside_runner_interval(self) -> None:
        self.assertEqual(
            self.classify(f"300 1 300 {self.host}\n", runner=0),
            [f"300 1 {self.host}"],
        )

    def test_duplicate_same_path_host_outside_launch_group_is_rejected(self) -> None:
        snapshot = (
            "200 10 200 /usr/bin/python3\n"
            f"300 1 200 {self.host}\n"
            f"301 1 301 {self.host}\n"
        )
        self.assertEqual(self.classify(snapshot), [f"301 1 {self.host}"])

    def test_two_launch_correlated_hosts_are_both_rejected(self) -> None:
        snapshot = (
            "200 10 200 /usr/bin/python3\n"
            f"300 1 200 {self.host}\n"
            f"301 1 200 {self.host}\n"
        )
        self.assertEqual(
            self.classify(snapshot),
            [f"300 1 {self.host}", f"301 1 {self.host}"],
        )

    def test_descendant_that_leaves_launch_process_group_is_rejected(self) -> None:
        snapshot = (
            "200 10 200 /usr/bin/python3\n"
            "201 200 201 /usr/bin/xcodebuild\n"
        )
        self.assertEqual(self.classify(snapshot), ["201 200 /usr/bin/xcodebuild"])

    def test_wrong_plainsong_and_unrelated_xcodebuild_are_rejected(self) -> None:
        other_host = "/private/tmp/other/Plainsong.app/Contents/MacOS/Plainsong"
        snapshot = f"301 1 301 {other_host}\n302 1 302 /usr/bin/xcodebuild\n"
        self.assertEqual(
            self.classify(snapshot),
            [f"301 1 {other_host}", "302 1 /usr/bin/xcodebuild"],
        )

    def test_cleanup_signals_only_owned_group_not_unrelated_group(self) -> None:
        command = f"""
source {shlex.quote(str(self.helper))}
/usr/bin/python3 -c 'import os; os.setsid(); os.execl("/bin/sleep", "sleep", "30")' &
runner=$!
/usr/bin/python3 -c 'import os; os.setsid(); os.execl("/bin/sleep", "sleep", "30")' &
unrelated=$!
F2_RUNNER_LIFECYCLE=signalable
F2_ACTIVE_RUNNER_PID=$runner
/bin/sleep 0.1
f2_terminate_run_tree "$runner" TERM || exit 20
builtin wait "$runner" 2>/dev/null || true
/bin/kill -0 "$unrelated" 2>/dev/null || exit 21
/bin/kill -TERM "-$unrelated"
builtin wait "$unrelated" 2>/dev/null || true
"""
        completed = subprocess.run(
            ["/bin/bash", "--noprofile", "--norc", "-c", command],
            capture_output=True,
            text=True,
            check=False,
            timeout=5,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_cleanup_has_no_path_wide_host_selection(self) -> None:
        source = self.helper.read_text(encoding="utf-8")
        self.assertNotIn("f2_exact_host_pids", source)
        self.assertNotIn("f2_owned_run_pids", source)
        self.assertIn('/bin/kill -"$signal" "-$runner_pid"', source)

    def test_reap_only_runner_state_never_signals_a_reused_group(self) -> None:
        unrelated = subprocess.Popen(["/bin/sleep", "30"], start_new_session=True)
        try:
            command = (
                f"source {shlex.quote(str(self.helper))}; "
                "F2_RUNNER_LIFECYCLE=reap-only; "
                f"F2_ACTIVE_RUNNER_PID={unrelated.pid}; "
                f"f2_terminate_run_tree {unrelated.pid} TERM"
            )
            completed = subprocess.run(
                ["/bin/bash", "--noprofile", "--norc", "-c", command],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(completed.returncode, 2, completed.stderr)
            self.assertIsNone(unrelated.poll())
        finally:
            if unrelated.poll() is None:
                os.killpg(unrelated.pid, signal.SIGTERM)
                unrelated.wait(timeout=2)

    def test_runner_trap_window_never_signals_reused_group(self) -> None:
        unrelated = subprocess.Popen(["/bin/sleep", "30"], start_new_session=True)
        try:
            capture = self.helper.parent
            command = f"""
source {shlex.quote(str(capture / 'processes.sh'))}
source {shlex.quote(str(capture / 'monitor.sh'))}
source {shlex.quote(str(capture / 'run.sh'))}
F2_CONTROL_DIRECTORY=$(/usr/bin/mktemp -d /private/tmp/plainsong-f2-monitor.XXXXXX)
F2_CONTROL_IDENTITY=$(/usr/bin/stat -f '%d:%i' "$F2_CONTROL_DIRECTORY")
F2_ACTIVE_RUNNER_PID={unrelated.pid}
F2_RUNNER_LIFECYCLE=reap-only
f2_capture_exit
"""
            completed = subprocess.run(
                ["/bin/bash", "--noprofile", "--norc", "-c", command],
                capture_output=True,
                text=True,
                check=False,
                timeout=2,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIsNone(unrelated.poll())
        finally:
            if unrelated.poll() is None:
                os.killpg(unrelated.pid, signal.SIGTERM)
                unrelated.wait(timeout=2)

    def test_runner_closes_signal_path_before_wait_can_reap(self) -> None:
        run_source = self.helper.with_name("run.sh").read_text(encoding="utf-8")
        wait_function = run_source.split("f2_wait_runner() {", 1)[1].split(
            "\nf2_stop_and_reap_runner()", 1
        )[0]
        closed = wait_function.index("f2_runner_enter_reap_only")
        drain = wait_function.index(': > "$session_drain"', closed)
        reap = wait_function.index('builtin wait "$F2_ACTIVE_RUNNER_PID"', drain)
        cleared = wait_function.index("F2_RUNNER_LIFECYCLE=cleared", reap)
        self.assertLess(closed, drain)
        self.assertLess(drain, reap)
        self.assertLess(reap, cleared)

    def test_failed_group_inspection_is_not_treated_as_drained(self) -> None:
        command = (
            f"source {shlex.quote(str(self.helper))}; "
            "f2_process_table_snapshot() { return 77; }; "
            "f2_run_group_has_live_member 200; exit $?"
        )
        completed = subprocess.run(
            ["/bin/bash", "--noprofile", "--norc", "-c", command],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(completed.returncode, 2, completed.stderr)

    def test_failed_group_inspection_stops_bounded_wait(self) -> None:
        command = (
            f"source {shlex.quote(str(self.helper))}; "
            "f2_process_table_snapshot() { return 77; }; "
            "f2_wait_run_group_members_gone 200 100; exit $?"
        )
        completed = subprocess.run(
            ["/bin/bash", "--noprofile", "--norc", "-c", command],
            capture_output=True,
            text=True,
            check=False,
            timeout=2,
        )
        self.assertEqual(completed.returncode, 2, completed.stderr)

    def test_term_resistant_monitor_is_killed_reaped_before_control_cleanup(self) -> None:
        capture = self.helper.parent
        command = f"""
source {shlex.quote(str(capture / 'processes.sh'))}
source {shlex.quote(str(capture / 'monitor.sh'))}
source {shlex.quote(str(capture / 'run.sh'))}
F2_CONTROL_DIRECTORY=$(/usr/bin/mktemp -d /private/tmp/plainsong-f2-monitor.XXXXXX)
F2_CONTROL_IDENTITY=$(/usr/bin/stat -f '%d:%i' "$F2_CONTROL_DIRECTORY")
/bin/bash --noprofile --norc -c 'trap "" TERM; while :; do /bin/sleep 1; done' &
F2_ACTIVE_MONITOR_PID=$!
F2_MONITOR_LIFECYCLE=signalable
/bin/sleep 0.1
if f2_cleanup_control_directory; then exit 20; fi
[[ -d "$F2_CONTROL_DIRECTORY" ]] || exit 21
f2_stop_monitor "$F2_ACTIVE_MONITOR_PID" 2 || exit 22
[[ -z "$F2_ACTIVE_MONITOR_PID" ]] || exit 23
f2_cleanup_control_directory || exit 24
[[ -z "$F2_CONTROL_DIRECTORY" ]] || exit 25
"""
        completed = subprocess.run(
            ["/bin/bash", "--noprofile", "--norc", "-c", command],
            capture_output=True,
            text=True,
            check=False,
            timeout=5,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_stopped_monitor_is_not_mistaken_for_a_reaped_job(self) -> None:
        capture = self.helper.parent
        command = f"""
source {shlex.quote(str(capture / 'processes.sh'))}
source {shlex.quote(str(capture / 'monitor.sh'))}
/bin/bash --noprofile --norc -c 'while :; do /bin/sleep 1; done' &
F2_ACTIVE_MONITOR_PID=$!
F2_MONITOR_LIFECYCLE=signalable
F2_CONTROL_DIRECTORY=$(/usr/bin/mktemp -d /private/tmp/plainsong-f2-monitor.XXXXXX)
/bin/kill -STOP "$F2_ACTIVE_MONITOR_PID"
/bin/sleep 0.1
if f2_wait_monitor_stopped "$F2_ACTIVE_MONITOR_PID" 1; then exit 20; fi
f2_stop_monitor "$F2_ACTIVE_MONITOR_PID" 1 || exit 21
[[ -z "$F2_ACTIVE_MONITOR_PID" ]] || exit 22
"""
        completed = subprocess.run(
            ["/bin/bash", "--noprofile", "--norc", "-c", command],
            capture_output=True,
            text=True,
            check=False,
            timeout=5,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_failed_monitor_inspection_is_not_treated_as_stopped(self) -> None:
        capture = self.helper.parent
        command = f"""
source {shlex.quote(str(capture / 'monitor.sh'))}
F2_CONTROL_DIRECTORY=$(/usr/bin/mktemp -d /private/tmp/plainsong-f2-monitor.XXXXXX)
f2_monitor_process_state() {{ return 2; }}
f2_wait_monitor_stopped 12345 100
exit $?
"""
        completed = subprocess.run(
            ["/bin/bash", "--noprofile", "--norc", "-c", command],
            capture_output=True,
            text=True,
            check=False,
            timeout=2,
        )
        self.assertEqual(completed.returncode, 2, completed.stderr)

    def test_failed_monitor_inspection_kills_owned_job_without_unbounded_wait(self) -> None:
        capture = self.helper.parent
        command = f"""
source {shlex.quote(str(capture / 'monitor.sh'))}
F2_CONTROL_DIRECTORY=$(/usr/bin/mktemp -d /private/tmp/plainsong-f2-monitor.XXXXXX)
/bin/bash --noprofile --norc -c 'trap "" TERM; while :; do /bin/sleep 1; done' &
F2_ACTIVE_MONITOR_PID=$!
F2_MONITOR_LIFECYCLE=signalable
f2_monitor_process_state() {{ return 2; }}
if f2_stop_monitor "$F2_ACTIVE_MONITOR_PID" 100; then exit 20; fi
[[ -z "$F2_ACTIVE_MONITOR_PID" && "$F2_MONITOR_LIFECYCLE" == cleared ]] || exit 21
"""
        completed = subprocess.run(
            ["/bin/bash", "--noprofile", "--norc", "-c", command],
            capture_output=True,
            text=True,
            check=False,
            timeout=2,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_failed_runner_identity_inspection_closes_before_owned_group_kill(self) -> None:
        capture = self.helper.parent
        command = f"""
source {shlex.quote(str(capture / 'processes.sh'))}
source {shlex.quote(str(capture / 'run.sh'))}
F2_CONTROL_DIRECTORY=$(/usr/bin/mktemp -d /private/tmp/plainsong-f2-monitor.XXXXXX)
/usr/bin/python3 -c 'import os,signal,time; os.setsid(); signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)' &
F2_ACTIVE_RUNNER_PID=$!
F2_RUNNER_LIFECYCLE=signalable
/bin/sleep 0.1
f2_runner_identity_snapshot() {{ return 2; }}
if f2_stop_and_reap_runner "$F2_ACTIVE_RUNNER_PID"; then exit 20; fi
[[ -z "$F2_ACTIVE_RUNNER_PID" && "$F2_RUNNER_LIFECYCLE" == cleared ]] || exit 21
"""
        completed = subprocess.run(
            ["/bin/bash", "--noprofile", "--norc", "-c", command],
            capture_output=True,
            text=True,
            check=False,
            timeout=2,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_reap_only_monitor_state_never_signals_a_reused_pid(self) -> None:
        unrelated = subprocess.Popen(["/bin/sleep", "30"])
        try:
            capture = self.helper.parent
            command = (
                f"source {shlex.quote(str(capture / 'monitor.sh'))}; "
                f"F2_ACTIVE_MONITOR_PID={unrelated.pid}; "
                "F2_MONITOR_LIFECYCLE=reap-only; "
                f"f2_stop_monitor {unrelated.pid} 1"
            )
            completed = subprocess.run(
                ["/bin/bash", "--noprofile", "--norc", "-c", command],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(completed.returncode, 2, completed.stderr)
            self.assertIsNone(unrelated.poll())
        finally:
            if unrelated.poll() is None:
                unrelated.terminate()
                unrelated.wait(timeout=2)

    def test_monitor_trap_window_never_signals_reused_pid(self) -> None:
        unrelated = subprocess.Popen(["/bin/sleep", "30"])
        try:
            capture = self.helper.parent
            command = f"""
source {shlex.quote(str(capture / 'processes.sh'))}
source {shlex.quote(str(capture / 'monitor.sh'))}
source {shlex.quote(str(capture / 'run.sh'))}
F2_CONTROL_DIRECTORY=$(/usr/bin/mktemp -d /private/tmp/plainsong-f2-monitor.XXXXXX)
F2_CONTROL_IDENTITY=$(/usr/bin/stat -f '%d:%i' "$F2_CONTROL_DIRECTORY")
F2_ACTIVE_MONITOR_PID={unrelated.pid}
F2_MONITOR_LIFECYCLE=reap-only
f2_capture_exit
"""
            completed = subprocess.run(
                ["/bin/bash", "--noprofile", "--norc", "-c", command],
                capture_output=True,
                text=True,
                check=False,
                timeout=2,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIsNone(unrelated.poll())
        finally:
            if unrelated.poll() is None:
                unrelated.terminate()
                unrelated.wait(timeout=2)

    def test_monitor_completion_closes_signal_path_before_reap_release(self) -> None:
        source = self.helper.with_name("monitor.sh").read_text(encoding="utf-8")
        wait_function = source.split("f2_wait_monitor() {", 1)[1].split(
            "\nf2_wait_monitor_stopped()", 1
        )[0]
        closed = wait_function.index("f2_monitor_enter_reap_only")
        released = wait_function.index('monitor-reap"', closed)
        reaped = wait_function.index('builtin wait "$monitor_pid"', released)
        self.assertLess(closed, released)
        self.assertLess(released, reaped)

    def test_classifier_never_uses_command_arguments_for_path_correlation(self) -> None:
        source = self.helper.read_text(encoding="utf-8")
        self.assertIn("comm=", source)
        self.assertIn("pgid=", source)
        self.assertNotIn("command=", source)
        self.assertNotIn("output_prefix", source)


if __name__ == "__main__":
    unittest.main()
