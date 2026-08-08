from __future__ import annotations

import subprocess
import unittest
from pathlib import Path


class ProcessOwnershipTests(unittest.TestCase):
    helper = Path(__file__).resolve().parent.parent / "editor-find-f2-capture" / "processes.sh"
    host = "/private/tmp/f2/run.products/Build/Products/Debug/Plainsong.app/Contents/MacOS/Plainsong"

    def classify(self, snapshot: str, runner: int = 200, allow_host: int = 1) -> list[str]:
        command = (
            f"source {self.helper!s}; "
            f"f2_classify_process_snapshot {runner} {allow_host} {self.host!s}"
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
            "200 10 /usr/bin/python3\n"
            "201 200 /usr/bin/xcodebuild\n"
            "202 201 /usr/bin/xctest\n"
            f"300 1 {self.host}\n"
        )
        self.assertEqual(self.classify(snapshot), [])

    def test_exact_host_is_competitor_outside_runner_interval(self) -> None:
        self.assertEqual(self.classify(f"300 1 {self.host}\n", runner=0, allow_host=0), [f"300 1 {self.host}"])

    def test_wrong_plainsong_and_unrelated_xcodebuild_are_rejected(self) -> None:
        other_host = "/private/tmp/other/Plainsong.app/Contents/MacOS/Plainsong"
        snapshot = f"301 1 {other_host}\n302 1 /usr/bin/xcodebuild\n"
        self.assertEqual(self.classify(snapshot), [f"301 1 {other_host}", "302 1 /usr/bin/xcodebuild"])

    def test_classifier_never_uses_command_arguments_for_path_correlation(self) -> None:
        source = self.helper.read_text(encoding="utf-8")
        self.assertIn("comm=", source)
        self.assertNotIn("command=", source)
        self.assertNotIn("output_prefix", source)


if __name__ == "__main__":
    unittest.main()
