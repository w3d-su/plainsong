#!/usr/bin/env python3
"""Run make targets ("lanes") in order or side by side, with one log per lane.

`make test-packages` builds the Swift packages and then tests them through this script
(docs/decisions/2026-11-15-ci-packages-build-then-test-lanes.md). Usage:

    run-test-lanes.py [--jobs N] [--directory DIR] <make target>...

Each lane is `make <target>` in DIR (default: the repository root).

--jobs 1 (the default) runs the lanes in the order given. They write straight to the
terminal, and the first failure stops the run, as a plain recipe would.

--jobs N runs up to N lanes at once, started in the order given. A lane's output goes to
its own file and is printed whole when the lane ends, so two lanes never interleave. A
failure does not stop the other lanes. The logs of failed lanes are printed last, after
every lane has ended, followed by one line per lane. On GitHub Actions a passed lane's
log is folded into a group and a failed lane adds an error annotation.

The exit status is 0 only when every lane passed. SIGINT, SIGTERM and SIGHUP stop the
lanes before this script exits: with --jobs 1 the signal is passed on to the running
make; with --jobs N each lane is its own session, and the whole session is stopped.
"""

import argparse
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPOSITORY = Path(__file__).resolve().parent.parent
STOP_SIGNALS = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
# How long a stopped lane gets to exit after SIGTERM before SIGKILL.
STOP_GRACE_SECONDS = 5
POLL_SECONDS = 0.1


class StopSignals:
    """Records the first stop signal instead of dying, so the lanes can be stopped first."""

    def __init__(self, on_signal=None):
        self.received = None
        self.on_signal = on_signal
        self.previous = {}

    def __enter__(self):
        self.previous = {number: signal.signal(number, self.handle) for number in STOP_SIGNALS}
        return self

    def __exit__(self, *_exception):
        for number, handler in self.previous.items():
            signal.signal(number, handler)

    def handle(self, number, _frame):
        if self.received is None:
            self.received = number
        if self.on_signal:
            self.on_signal(number)


class Lane:
    def __init__(self, number, target):
        self.number = number
        self.target = target
        self.process = None
        self.log = None
        self.started = None
        self.seconds = None
        self.status = None

    @property
    def outcome(self):
        if self.status is None:
            if self.seconds is not None:
                return f"did not finish after {self.seconds} s"
            return "did not finish"
        if self.status == 0:
            return f"passed in {self.seconds} s"
        return f"FAILED ({describe_status(self.status)}) after {self.seconds} s"


def describe_status(status):
    if status < 0:
        return f"signal {-status}"
    return f"exit {status}"


def exit_status(status):
    return 128 - status if status < 0 else status


def say(text):
    print(text, flush=True)


def make_command(target):
    return ["make", "--no-print-directory", target]


def on_github():
    return os.environ.get("GITHUB_ACTIONS") == "true"


def run_in_order(targets, directory):
    current = []

    def pass_on(number):
        for process in current:
            process.send_signal(number)

    with StopSignals(pass_on) as stop_signals:
        for number, target in enumerate(targets, 1):
            say(f"==> lane {number} of {len(targets)}: {target}")
            process = subprocess.Popen(make_command(target), cwd=directory)
            current.append(process)
            if stop_signals.received is not None:
                process.send_signal(stop_signals.received)
            status = process.wait()
            current.clear()
            if stop_signals.received is not None:
                return 128 + stop_signals.received
            if status != 0:
                skipped = len(targets) - number
                after = f"; the {skipped} after it did not run" if skipped else ""
                say(f"==> {target}: FAILED ({describe_status(status)}){after}")
                return exit_status(status)
    return 0


def start(lane, work, directory):
    lane.log = Path(work) / f"{lane.number}.log"
    lane.started = time.monotonic()
    with open(lane.log, "wb") as log:
        lane.process = subprocess.Popen(
            make_command(lane.target),
            cwd=directory,
            stdin=subprocess.DEVNULL,
            stdout=log,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
    say(f"==> {lane.target}: started")


def print_log(lane, folded):
    title = f"{lane.target}: {lane.outcome}"
    grouped = folded and on_github()
    say(f"::group::{title}" if grouped else f"----- {title} -----")
    with open(lane.log, "rb") as log:
        shutil.copyfileobj(log, sys.stdout.buffer)
        if log.tell() > 0:
            log.seek(-1, os.SEEK_END)
            if log.read(1) != b"\n":
                sys.stdout.buffer.write(b"\n")
    sys.stdout.buffer.flush()
    say("::endgroup::" if grouped else f"----- end of {lane.target} -----")


def finish(lane, status):
    lane.status = status
    lane.seconds = round(time.monotonic() - lane.started)
    if status == 0:
        print_log(lane, folded=True)
        return
    say(f"==> {lane.target}: {lane.outcome}; its log follows the other lanes")
    if on_github():
        say(f"::error title={lane.target} failed::{lane.outcome}. Its log is printed after the other lanes.")


def stop_grace_seconds():
    value = os.environ.get("PLAINSONG_TEST_LANES_STOP_GRACE_SECONDS")
    return STOP_GRACE_SECONDS if value is None else max(0.0, float(value))


def session_members(session_id):
    result = subprocess.run(["ps", "-x", "-o", "pid="], capture_output=True, text=True)
    if result.returncode != 0:
        return []
    members = []
    for line in result.stdout.splitlines():
        text = line.strip()
        if not text:
            continue
        try:
            pid = int(text)
            if os.getsid(pid) == session_id:
                members.append((pid, os.getpgid(pid)))
        except (ValueError, OSError):
            continue
    return members


def signal_lane(lane, number):
    session_id = lane.process.pid
    members = session_members(session_id)
    groups = {session_id}
    for _pid, pgid in members:
        groups.add(pgid)
    for pgid in sorted(groups):
        try:
            os.killpg(pgid, number)
        except ProcessLookupError:
            pass
        except PermissionError:
            # macOS answers EPERM, not ESRCH, for a group whose only member has exited
            # and is not reaped yet. Popen.send_signal ignores a process that has ended.
            if pgid == session_id:
                lane.process.send_signal(number)
            else:
                for pid, member_pgid in members:
                    if member_pgid == pgid:
                        try:
                            os.kill(pid, number)
                        except ProcessLookupError:
                            pass


def stop(running):
    for lane in running:
        signal_lane(lane, signal.SIGINT)
    for lane in running:
        signal_lane(lane, signal.SIGTERM)
    deadline = time.monotonic() + stop_grace_seconds()
    for lane in running:
        try:
            lane.process.wait(timeout=max(0, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            pass
    # A lane's make can exit before something it started does; the session is what ends.
    for lane in running:
        signal_lane(lane, signal.SIGKILL)
        lane.process.wait()


def run_side_by_side(targets, directory, jobs):
    lanes = [Lane(number, target) for number, target in enumerate(targets, 1)]
    waiting = list(lanes)
    running = []
    began = time.monotonic()
    work = tempfile.mkdtemp(prefix="plainsong-test-lanes.")
    try:
        with StopSignals() as stop_signals:
            while (waiting or running) and stop_signals.received is None:
                while waiting and len(running) < jobs:
                    lane = waiting.pop(0)
                    running.append(lane)
                    start(lane, work, directory)
                time.sleep(POLL_SECONDS)
                for lane in list(running):
                    status = lane.process.poll()
                    if status is not None:
                        running.remove(lane)
                        finish(lane, status)
            if stop_signals.received is not None:
                say(f"==> {signal.Signals(stop_signals.received).name}: stopping the running lanes")
                stop(running)
                for lane in running:
                    lane.seconds = round(time.monotonic() - lane.started)
                for lane in lanes:
                    if lane.status not in (None, 0) or lane in running:
                        print_log(lane, folded=False)
                return 128 + stop_signals.received
        failed = [lane for lane in lanes if lane.status != 0]
        for lane in failed:
            print_log(lane, folded=False)
        elapsed = round(time.monotonic() - began)
        verdict = f"{len(lanes) - len(failed)} passed"
        if failed:
            verdict += f", {len(failed)} FAILED"
        say(f"==> {len(lanes)} lanes, up to {jobs} at once, {elapsed} s: {verdict}")
        for lane in lanes:
            say(f"    {lane.target}: {lane.outcome}")
        return 1 if failed else 0
    finally:
        shutil.rmtree(work, ignore_errors=True)


def positive(text):
    value = int(text)
    if value < 1:
        raise argparse.ArgumentTypeError("must be 1 or more")
    return value


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--jobs", type=positive, default=1, help="lanes to run at once (default: 1)")
    parser.add_argument("--directory", default=str(REPOSITORY), help="where make runs (default: the repository root)")
    parser.add_argument("targets", nargs="+", metavar="target", help="a make target; each is one lane")
    arguments = parser.parse_args(argv[1:])
    if arguments.jobs == 1:
        return run_in_order(arguments.targets, arguments.directory)
    return run_side_by_side(arguments.targets, arguments.directory, arguments.jobs)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
