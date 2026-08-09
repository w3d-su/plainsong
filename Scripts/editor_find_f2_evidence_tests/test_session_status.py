from __future__ import annotations

import importlib.util
import os
import shlex
import signal
import stat
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path


class SessionStatusTests(unittest.TestCase):
    module_path = (
        Path(__file__).resolve().parent.parent
        / "editor-find-f2-capture"
        / "session_status.py"
    )

    def run_owned_session_cleanup(
        self,
        temporary: str,
    ) -> subprocess.CompletedProcess[str]:
        control = Path(temporary)
        capture = self.module_path.parent
        ready = control / "session-ready"
        go = control / "session-go"
        status = control / "session-status"
        drain = control / "session-drain"
        command = f"""
source {shlex.quote(str(capture / 'processes.sh'))}
source {shlex.quote(str(capture / 'monitor.sh'))}
source {shlex.quote(str(capture / 'run.sh'))}
F2_CONTROL_DIRECTORY={shlex.quote(str(control))}
/usr/bin/python3 -I {shlex.quote(str(self.module_path))} \
    {shlex.quote(str(ready))} {shlex.quote(str(go))} \
    {shlex.quote(str(status))} {shlex.quote(str(drain))} \
    /bin/sleep 30 &
F2_ACTIVE_RUNNER_PID=$!
F2_RUNNER_LIFECYCLE=signalable
f2_wait_for_file {shlex.quote(str(ready))} "$F2_ACTIVE_RUNNER_PID" || exit 20
f2_stop_and_reap_runner "$F2_ACTIVE_RUNNER_PID" || exit 26
[[ -z "$F2_ACTIVE_RUNNER_PID" ]] || exit 27
[[ "$F2_RUNNER_LIFECYCLE" == cleared ]] || exit 28
[[ ! -e "$F2_CONTROL_DIRECTORY/session-status" ]] || exit 29
[[ -e "$F2_CONTROL_DIRECTORY/session-drain" ]] || exit 30
"""
        return subprocess.run(
            ["/bin/bash", "--noprofile", "--norc", "-c", command],
            capture_output=True,
            text=True,
            check=False,
            timeout=10,
        )

    def wait_for_path(self, path: Path, timeout: float = 3) -> None:
        deadline = time.monotonic() + timeout
        while not path.exists() and time.monotonic() < deadline:
            time.sleep(0.005)
        self.assertTrue(path.exists(), f"timed out waiting for {path}")

    def test_real_supervisor_pre_go_cleanup_reaps_and_clears_ownership(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="f2-session-pre-go.",
            dir="/private/tmp",
        ) as temporary:
            completed = self.run_owned_session_cleanup(temporary)
            self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_real_runner_restores_default_term_policy_before_exec(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="f2-session-post-go.",
            dir="/private/tmp",
        ) as temporary:
            control = Path(temporary)
            ready = control / "session-ready"
            go = control / "session-go"
            status = control / "session-status"
            drain = control / "session-drain"
            runner_started = control / "runner-started"
            supervisor = subprocess.Popen(
                [
                    "/usr/bin/python3",
                    "-I",
                    str(self.module_path),
                    str(ready),
                    str(go),
                    str(status),
                    str(drain),
                    "/bin/sh",
                    "-c",
                    'printf ready > "$1"; exec /bin/sleep 30',
                    "f2-runner",
                    str(runner_started),
                ]
            )
            try:
                self.wait_for_path(ready)
                go.touch(mode=0o400)
                self.wait_for_path(runner_started)
                os.killpg(supervisor.pid, signal.SIGTERM)
                self.wait_for_path(status)
                self.assertEqual(status.read_text(encoding="ascii"), "143\n")
                drain.touch(mode=0o400)
                self.assertEqual(supervisor.wait(timeout=3), 143)
            finally:
                drain.touch(mode=0o400, exist_ok=True)
                if supervisor.poll() is None:
                    try:
                        os.killpg(supervisor.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    supervisor.wait(timeout=3)

    def test_parent_cannot_observe_empty_status_before_atomic_publication(self) -> None:
        spec = importlib.util.spec_from_file_location("f2_session_status", self.module_path)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory(
            prefix="f2-session-status.",
            dir="/private/tmp",
        ) as temporary:
            final = Path(temporary) / "session-status"
            paused = threading.Event()
            release = threading.Event()

            def before_publish(temporary_path: Path) -> None:
                self.assertEqual(temporary_path.read_bytes(), b"17\n")
                self.assertEqual(
                    stat.S_IMODE(temporary_path.stat().st_mode),
                    0o400,
                )
                paused.set()
                self.assertTrue(release.wait(timeout=2))

            worker = threading.Thread(
                target=module.publish_status_atomically,
                args=(final, 17, before_publish),
            )
            worker.start()
            self.assertTrue(paused.wait(timeout=2))
            self.assertFalse(final.exists())
            release.set()
            worker.join(timeout=2)
            self.assertFalse(worker.is_alive())
            self.assertEqual(final.read_bytes(), b"17\n")


if __name__ == "__main__":
    unittest.main()
