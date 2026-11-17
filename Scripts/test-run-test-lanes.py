#!/usr/bin/env python3
"""Regression coverage for run-test-lanes.py, which `make test-packages` runs through."""

import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

RUNNER = Path(__file__).with_name("run-test-lanes.py")
REPOSITORY_MAKEFILE = RUNNER.resolve().parent.parent / "Makefile"

# `meet-a.b` passes only once lane `meet-b.a` has started too, so the pair proves that
# two lanes ran at the same time without a sleep deciding the result.
FIXTURE_MAKEFILE = r"""
self = $(basename $*)
other = $(subst .,,$(suffix $*))
wait_for_other = touch started-$(self); \
	for attempt in $$(seq 1 200); do [ -e started-$(other) ] && break; sleep 0.05; done; \
	[ -e started-$(other) ] || { echo "$(self) never met $(other)"; exit 1; }

print-%:
	@echo "$* first"; echo "$* second"

fail-%:
	@echo "$* before failing"; exit 3

unterminated-%:
	@printf '%s' "$* has no final newline"

meet-%:
	@$(wait_for_other); echo "$(self) met $(other)"

chatter-%:
	@$(wait_for_other); for line in $$(seq 1 300); do echo "$(self) $$line"; done

count-%:
	@echo start >> events; sleep 0.2; echo end >> events

# The sleep does not hold the lane's output open, so a reader of that output never
# waits for a sleep that outlived the lane.
hang-%:
	@echo "$* hanging"; /bin/sleep 60 > /dev/null 2>&1 & echo $$! > sleeper-$*.tmp; mv sleeper-$*.tmp sleeper-$*.pid; wait

newpg-hang-%:
	@$(PYTHON) -c 'import os, pathlib, sys, time; os.setpgid(0, 0); print(f"{sys.argv[1]} newpg", flush=True); pathlib.Path(f"sleeper-{sys.argv[1]}.tmp").write_text(str(os.getpid())); os.replace(f"sleeper-{sys.argv[1]}.tmp", f"sleeper-{sys.argv[1]}.pid"); time.sleep(60)' "$*"

stubborn-hang-%:
	@$(PYTHON) -c 'import os, pathlib, signal, sys, time; os.setpgid(0, 0); signal.signal(signal.SIGINT, signal.SIG_IGN); signal.signal(signal.SIGTERM, signal.SIG_IGN); print(f"{sys.argv[1]} stubborn", flush=True); pathlib.Path(f"sleeper-{sys.argv[1]}.tmp").write_text(str(os.getpid())); os.replace(f"sleeper-{sys.argv[1]}.tmp", f"sleeper-{sys.argv[1]}.pid"); time.sleep(60)' "$*"

signal-lane-%:
	@$(PYTHON) -c 'import os, signal, sys; print(f"{sys.argv[1]} before signal", flush=True); os.killpg(0, signal.SIGKILL)' "$*"
"""


class RunTestLanesTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="plainsong-test-lanes-tests.")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        (self.directory / "Makefile").write_text(FIXTURE_MAKEFILE)

    def environment(self, github=False, stop_grace=None):
        # The fixture's make must not inherit the flags or GitHub mode of the make or
        # workflow that runs these tests.
        environment = {
            name: value
            for name, value in os.environ.items()
            if name not in ("MAKEFLAGS", "MFLAGS", "MAKELEVEL", "GITHUB_ACTIONS", "PLAINSONG_TEST_LANES_STOP_GRACE_SECONDS")
        }
        if github:
            environment["GITHUB_ACTIONS"] = "true"
        if stop_grace is not None:
            environment["PLAINSONG_TEST_LANES_STOP_GRACE_SECONDS"] = str(stop_grace)
        environment["PYTHON"] = sys.executable
        return environment

    def command(self, jobs, lanes):
        return [sys.executable, str(RUNNER), "--directory", str(self.directory), "--jobs", str(jobs), *lanes]

    def run_lanes(self, jobs, *lanes, github=False):
        return subprocess.run(
            self.command(jobs, lanes),
            env=self.environment(github),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=120,
        )

    def test_one_job_runs_lanes_in_order_and_stops_at_the_first_failure(self):
        result = self.run_lanes(1, "print-a", "fail-b", "print-c")

        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertLess(result.stdout.index("a second"), result.stdout.index("b before failing"))
        self.assertIn("==> fail-b: FAILED (exit 2); the 1 after it did not run", result.stdout)
        self.assertNotIn("c first", result.stdout)

    def test_one_job_passes_when_every_lane_passes(self):
        result = self.run_lanes(1, "print-a", "print-b")

        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("==> lane 2 of 2: print-b", result.stdout)
        self.assertIn("b second", result.stdout)

    def test_several_jobs_run_lanes_at_the_same_time(self):
        result = self.run_lanes(2, "meet-a.b", "meet-b.a")

        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("a met b", result.stdout)
        self.assertIn("b met a", result.stdout)
        self.assertIn("==> 2 lanes, up to 2 at once", result.stdout)

    def test_each_log_is_printed_whole(self):
        result = self.run_lanes(2, "chatter-a.b", "chatter-b.a")

        self.assertEqual(result.returncode, 0, result.stdout)
        lines = result.stdout.splitlines()
        for lane, name in (("chatter-a.b", "a"), ("chatter-b.a", "b")):
            first = next(index for index, line in enumerate(lines) if line.startswith(f"----- {lane}: passed"))
            last = lines.index(f"----- end of {lane} -----")
            self.assertEqual(lines[first + 1:last], [f"{name} {line}" for line in range(1, 301)])

    def test_a_failure_lets_the_other_lanes_finish_and_prints_its_log_last(self):
        result = self.run_lanes(3, "print-a", "fail-b", "print-c")

        self.assertEqual(result.returncode, 1, result.stdout)
        output = result.stdout
        self.assertIn("==> fail-b: FAILED (exit 2) after", output)
        failed_log = output.index("----- fail-b: FAILED (exit 2) after")
        self.assertLess(output.index("----- end of print-a -----"), failed_log)
        self.assertLess(output.index("----- end of print-c -----"), failed_log)
        self.assertLess(failed_log, output.index("b before failing"))
        self.assertEqual(output.count("b before failing"), 1)
        self.assertIn("==> 3 lanes, up to 3 at once", output)
        self.assertIn("2 passed, 1 FAILED", output)
        self.assertNotIn("::", output)

    def test_no_more_lanes_run_at_once_than_jobs(self):
        result = self.run_lanes(2, "count-a", "count-b", "count-c", "count-d", "count-e")

        self.assertEqual(result.returncode, 0, result.stdout)
        events = (self.directory / "events").read_text().split()
        self.assertEqual(sorted(events), ["end"] * 5 + ["start"] * 5)
        running = 0
        for event in events:
            running += 1 if event == "start" else -1
            self.assertLessEqual(running, 2, events)

    def test_a_log_without_a_final_newline_does_not_swallow_the_footer(self):
        result = self.run_lanes(2, "unterminated-a", "print-b")

        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("a has no final newline\n----- end of unterminated-a -----\n", result.stdout)

    def test_github_folds_passed_logs_and_annotates_failures(self):
        result = self.run_lanes(2, "print-a", "fail-b", github=True)

        self.assertEqual(result.returncode, 1, result.stdout)
        output = result.stdout
        self.assertRegex(output, r"::group::print-a: passed in \d+ s\na first\na second\n::endgroup::\n")
        self.assertRegex(output, r"::error title=fail-b failed::FAILED \(exit 2\) after \d+ s\.")
        self.assertRegex(output, r"----- fail-b: FAILED \(exit 2\) after \d+ s -----\nb before failing\n")
        self.assertNotIn("::group::fail-b", output)

    def test_an_interrupt_stops_running_lanes_and_what_they_started(self):
        runner = subprocess.Popen(
            self.command(2, ["hang-a", "print-b"]),
            env=self.environment(),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        self.addCleanup(runner.stdout.close)
        self.addCleanup(runner.kill)
        sleeper = self.wait_for_sleeper()

        runner.send_signal(signal.SIGTERM)
        output, _ = runner.communicate(timeout=30)

        self.assertEqual(runner.returncode, 128 + signal.SIGTERM, output)
        self.assertIn("==> SIGTERM: stopping the running lanes", output)
        self.assertIn("----- hang-a: did not finish", output)
        self.assertIn("a hanging", output)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and self.is_running(sleeper):
            time.sleep(0.02)
        self.assertFalse(self.is_running(sleeper), "the lane's child outlived the interrupt")

    def test_sigint_stops_child_in_its_own_process_group(self):
        runner = subprocess.Popen(
            self.command(2, ["newpg-hang-a", "print-b"]),
            env=self.environment(),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        self.addCleanup(runner.stdout.close)
        self.addCleanup(runner.kill)
        sleeper = self.wait_for_sleeper()
        self.addCleanup(self.kill_quietly, sleeper)

        runner.send_signal(signal.SIGINT)
        output, _ = runner.communicate(timeout=30)

        self.assertEqual(runner.returncode, 128 + signal.SIGINT, output)
        self.assertIn("==> SIGINT: stopping the running lanes", output)
        self.assertIn("----- newpg-hang-a: did not finish", output)
        self.assertIn("a newpg", output)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and self.is_running(sleeper):
            time.sleep(0.02)
        self.assertFalse(self.is_running(sleeper), "a child in its own process group outlived SIGINT")

    def test_sighup_escalates_to_sigkill_when_session_child_ignores_term(self):
        runner = subprocess.Popen(
            self.command(2, ["stubborn-hang-a", "print-b"]),
            env=self.environment(stop_grace=0.2),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        self.addCleanup(runner.stdout.close)
        self.addCleanup(runner.kill)
        sleeper = self.wait_for_sleeper()
        self.addCleanup(self.kill_quietly, sleeper)

        runner.send_signal(signal.SIGHUP)
        output, _ = runner.communicate(timeout=30)

        self.assertEqual(runner.returncode, 128 + signal.SIGHUP, output)
        self.assertIn("==> SIGHUP: stopping the running lanes", output)
        self.assertIn("----- stubborn-hang-a: did not finish", output)
        self.assertIn("a stubborn", output)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and self.is_running(sleeper):
            time.sleep(0.02)
        self.assertFalse(self.is_running(sleeper), "a child ignoring SIGINT/SIGTERM outlived SIGKILL escalation")

    def test_interrupt_prints_logs_of_already_failed_and_running_lanes(self):
        runner = subprocess.Popen(
            self.command(2, ["fail-a", "hang-b", "newpg-hang-c", "print-d"]),
            env=self.environment(),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        self.addCleanup(runner.stdout.close)
        self.addCleanup(runner.kill)
        prefix = []
        seen_failure = False
        while True:
            line = runner.stdout.readline()
            if not line:
                break
            prefix.append(line)
            if "==> fail-a: FAILED" in line:
                seen_failure = True
                break
        self.assertTrue(seen_failure, "".join(prefix))
        sleeper_b = self.wait_for_sleeper("b")
        sleeper_c = self.wait_for_sleeper("c")
        self.addCleanup(self.kill_quietly, sleeper_b)
        self.addCleanup(self.kill_quietly, sleeper_c)

        runner.send_signal(signal.SIGINT)
        rest, _ = runner.communicate(timeout=30)
        output = "".join(prefix) + rest

        self.assertEqual(runner.returncode, 128 + signal.SIGINT, output)
        self.assertIn("----- fail-a: FAILED (exit 2) after", output)
        self.assertIn("a before failing", output)
        self.assertIn("----- hang-b: did not finish", output)
        self.assertIn("b hanging", output)
        self.assertIn("----- newpg-hang-c: did not finish", output)
        self.assertIn("c newpg", output)
        self.assertNotIn("----- print-d:", output)

    def test_one_job_passes_a_stop_signal_on_and_runs_nothing_more(self):
        runner = subprocess.Popen(
            self.command(1, ["hang-a", "print-b"]),
            env=self.environment(),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        self.addCleanup(runner.stdout.close)
        self.addCleanup(runner.kill)
        sleeper = self.wait_for_sleeper()
        # make stops its recipe shell, not the sleep that shell left in the background.
        self.addCleanup(self.kill_quietly, sleeper)

        runner.send_signal(signal.SIGTERM)
        output, _ = runner.communicate(timeout=30)

        self.assertEqual(runner.returncode, 128 + signal.SIGTERM, output)
        self.assertNotIn("b first", output)

    def wait_for_sleeper(self, name="a"):
        sleeper_file = self.directory / f"sleeper-{name}.pid"
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline and not (sleeper_file.exists() and sleeper_file.read_text().strip()):
            time.sleep(0.02)
        return int(sleeper_file.read_text())

    @staticmethod
    def kill_quietly(pid):
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass

    @staticmethod
    def is_running(pid):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        return True

    def test_jobs_must_be_positive(self):
        result = self.run_lanes(0, "print-a")

        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertNotIn("a first", result.stdout)

    def test_a_lane_killed_by_a_signal_with_several_jobs_lets_other_lanes_finish(self):
        result = self.run_lanes(2, "signal-lane-a", "print-b")

        self.assertEqual(result.returncode, 1, result.stdout)
        output = result.stdout
        self.assertIn("==> signal-lane-a: FAILED (signal 9) after", output)
        self.assertIn("----- signal-lane-a: FAILED (signal 9) after", output)
        self.assertIn("a before signal", output)
        self.assertIn("b second", output)
        self.assertIn("1 passed, 1 FAILED", output)

    def test_makefile_lane_checks_reject_missing_or_duplicate_steps(self):
        def dry_run(*overrides):
            return subprocess.run(
                ["make", "-n", "-f", str(REPOSITORY_MAKEFILE), *overrides, "test-packages"],
                cwd=REPOSITORY_MAKEFILE.parent,
                env=self.environment(),
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=30,
            )

        ok = dry_run()
        self.assertEqual(ok.returncode, 0, ok.stdout)

        missing_package = dry_run("TEST_LANE_preview=")
        self.assertNotEqual(missing_package.returncode, 0, missing_package.stdout)
        self.assertIn("TEST_LANE_* must name package-test-<package> for each of:", missing_package.stdout)

        duplicate_package = dry_run("TEST_LANE_preview=package-test-PreviewKit package-test-EditorKit")
        self.assertNotEqual(duplicate_package.returncode, 0, duplicate_package.stdout)
        self.assertIn("A package is in two test lanes:", duplicate_package.stdout)

        missing_tooling = dry_run("TEST_LANE_editor=package-test-EditorKit")
        self.assertNotEqual(missing_tooling.returncode, 0, missing_tooling.stdout)
        self.assertIn("TEST_LANE_* must include test-packages-tooling exactly once.", missing_tooling.stdout)

        duplicate_tooling = dry_run("TEST_LANE_preview=package-test-PreviewKit test-packages-tooling")
        self.assertNotEqual(duplicate_tooling.returncode, 0, duplicate_tooling.stdout)
        self.assertIn("TEST_LANE_* must include test-packages-tooling exactly once.", duplicate_tooling.stdout)


if __name__ == "__main__":
    unittest.main()
