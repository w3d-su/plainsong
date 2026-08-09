from __future__ import annotations

import importlib.util
import stat
import tempfile
import threading
import unittest
from pathlib import Path


class SessionStatusTests(unittest.TestCase):
    module_path = (
        Path(__file__).resolve().parent.parent
        / "editor-find-f2-capture"
        / "session_status.py"
    )

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
