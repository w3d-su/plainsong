from __future__ import annotations

import os
import shlex
import shutil
import signal
import subprocess
import tempfile
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

    def test_cleanup_signals_only_owned_group_not_duplicate_host_path(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="f2-process-ownership.", dir="/private/tmp"
        ) as temporary:
            host = Path(temporary) / "Plainsong.app" / "Contents" / "MacOS" / "Plainsong"
            host.parent.mkdir(parents=True)
            shutil.copyfile("/bin/sleep", host)
            host.chmod(0o700)
            runner = subprocess.Popen([str(host), "30"], start_new_session=True)
            unrelated = subprocess.Popen([str(host), "30"], start_new_session=True)
            try:
                command = (
                    f"source {shlex.quote(str(self.helper))}; "
                    f"F2_ALLOWED_HOST_EXECUTABLE={shlex.quote(str(host))}; "
                    f"f2_terminate_run_tree {runner.pid} TERM"
                )
                subprocess.run(
                    ["/bin/bash", "--noprofile", "--norc", "-c", command],
                    check=True,
                    capture_output=True,
                    text=True,
                )
                runner.wait(timeout=2)
                self.assertIsNone(unrelated.poll())
            finally:
                if runner.poll() is None:
                    os.killpg(runner.pid, signal.SIGKILL)
                    runner.wait(timeout=2)
                if unrelated.poll() is None:
                    os.killpg(unrelated.pid, signal.SIGTERM)
                    unrelated.wait(timeout=2)

    def test_cleanup_has_no_path_wide_host_selection(self) -> None:
        source = self.helper.read_text(encoding="utf-8")
        self.assertNotIn("f2_exact_host_pids", source)
        self.assertNotIn("f2_owned_run_pids", source)
        self.assertIn('/bin/kill -"$signal" "-$runner_pid"', source)

    def test_classifier_never_uses_command_arguments_for_path_correlation(self) -> None:
        source = self.helper.read_text(encoding="utf-8")
        self.assertIn("comm=", source)
        self.assertIn("pgid=", source)
        self.assertNotIn("command=", source)
        self.assertNotIn("output_prefix", source)


if __name__ == "__main__":
    unittest.main()
