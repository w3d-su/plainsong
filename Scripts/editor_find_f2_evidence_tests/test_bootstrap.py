from __future__ import annotations

import os
import shlex
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


class BootstrapTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(
            prefix="f2-bootstrap-tests.", dir="/private/tmp"
        )
        self.root = Path(self.temporary.name)
        self.scripts = Path(__file__).resolve().parent.parent

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def copy_scripts(self) -> Path:
        destination = self.root / "Scripts"
        shutil.copytree(self.scripts, destination)
        return destination

    def hostile_path(self) -> tuple[Path, Path]:
        directory = self.root / "hostile-bin"
        directory.mkdir()
        marker = self.root / "hostile-path-ran"
        for name in ("dirname", "tr", "umask"):
            program = directory / name
            program.write_text(
                f"#!/bin/bash\n/usr/bin/touch {marker}\nexit 97\n",
                encoding="utf-8",
            )
            program.chmod(0o700)
        return directory, marker

    def run_with_inherited_umask(
        self,
        command: list[str],
        environment: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        quoted = shlex.join(command)
        return subprocess.run(
            ["/bin/bash", "--noprofile", "--norc", "-c", f"umask 000; exec {quoted}"],
            check=False,
            capture_output=True,
            text=True,
            cwd="/private/tmp",
            env=environment,
        )

    def test_shell_entrypoints_set_parent_umask_with_builtin(self) -> None:
        for name in (
            "build-editor-find-f2-performance-gate.sh",
            "capture-editor-find-f2-authoritative-run.sh",
            "run-editor-find-f2-performance-gate.sh",
        ):
            with self.subTest(name=name):
                source = (self.scripts / name).read_text(encoding="utf-8")
                umask_line = next(
                    line.strip() for line in source.splitlines() if "umask 077" in line
                )
                self.assertEqual(umask_line, "builtin umask 077")
                result = subprocess.run(
                    [
                        "/bin/bash",
                        "--noprofile",
                        "--norc",
                        "-c",
                        f"umask 000; {umask_line}; builtin umask",
                    ],
                    check=True,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(result.stdout.strip(), "0077")
                self.assertNotIn("/usr/bin/umask", source)

    def test_shell_entrypoints_do_not_resolve_preverification_tools_from_path(self) -> None:
        scripts = self.copy_scripts()
        hostile, marker = self.hostile_path()
        environment = os.environ.copy()
        environment["PATH"] = str(hostile)
        commands = (
            [
                str(scripts / "build-editor-find-f2-performance-gate.sh"),
                "Invalid",
                str(self.root / "fresh-derived-data"),
            ],
            [str(scripts / "capture-editor-find-f2-authoritative-run.sh")],
            [str(scripts / "run-editor-find-f2-performance-gate.sh")],
        )
        for command in commands:
            with self.subTest(entrypoint=Path(command[0]).name):
                result = self.run_with_inherited_umask(command, environment)
                self.assertNotEqual(result.returncode, 97)
                self.assertFalse(marker.exists(), result.stderr)

    def test_python_entrypoint_rejects_nonisolated_interpreter(self) -> None:
        script = self.scripts / "check-editor-find-f2-retained-evidence.py"
        result = subprocess.run(
            ["/usr/bin/python3", str(script), "--help"],
            check=False,
            capture_output=True,
            text=True,
            cwd="/private/tmp",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires isolated Python", result.stderr)

    def test_python_bootstrap_rejects_pinned_module_tamper(self) -> None:
        scripts = self.copy_scripts()
        target = scripts / "editor_find_f2_evidence" / "pack.py"
        target.write_bytes(target.read_bytes() + b"# tamper\n")
        result = subprocess.run(
            [str(scripts / "check-editor-find-f2-retained-evidence.py"), "--help"],
            check=False,
            capture_output=True,
            text=True,
            cwd="/private/tmp",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("module hash mismatch: pack.py", result.stderr)

    def test_capture_bootstrap_rejects_sourced_module_tamper(self) -> None:
        scripts = self.copy_scripts()
        target = scripts / "editor-find-f2-capture" / "processes.sh"
        target.write_bytes(target.read_bytes() + b"# tamper\n")
        result = subprocess.run(
            [str(scripts / "capture-editor-find-f2-authoritative-run.sh")],
            check=False,
            capture_output=True,
            text=True,
            cwd="/private/tmp",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("module hash mismatch", result.stderr)

    def test_capture_privileged_mode_ignores_bash_env(self) -> None:
        marker = self.root / "bash-env-ran"
        bash_env = self.root / "bash-env"
        bash_env.write_text(f"touch {marker}\n", encoding="utf-8")
        environment = os.environ.copy()
        environment["BASH_ENV"] = str(bash_env)
        result = subprocess.run(
            [str(self.scripts / "capture-editor-find-f2-authoritative-run.sh")],
            check=False,
            capture_output=True,
            text=True,
            cwd="/private/tmp",
            env=environment,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("usage:", result.stderr)
        self.assertFalse(marker.exists())

    def test_runner_bootstrap_rejects_sourced_module_tamper(self) -> None:
        scripts = self.copy_scripts()
        target = scripts / "editor-find-f2-runner" / "setup.sh"
        target.write_bytes(target.read_bytes() + b"# tamper\n")
        result = subprocess.run(
            [str(scripts / "run-editor-find-f2-performance-gate.sh")],
            check=False,
            capture_output=True,
            text=True,
            cwd="/private/tmp",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("module hash mismatch", result.stderr)

    def test_runner_privileged_mode_ignores_bash_env(self) -> None:
        marker = self.root / "runner-bash-env-ran"
        bash_env = self.root / "runner-bash-env"
        bash_env.write_text(f"touch {marker}\n", encoding="utf-8")
        environment = os.environ.copy()
        environment["BASH_ENV"] = str(bash_env)
        result = subprocess.run(
            [str(self.scripts / "run-editor-find-f2-performance-gate.sh")],
            check=False,
            capture_output=True,
            text=True,
            cwd="/private/tmp",
            env=environment,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("usage:", result.stderr)
        self.assertFalse(marker.exists())

    def test_build_wrapper_rejects_artifact_hasher_tamper(self) -> None:
        scripts = self.copy_scripts()
        target = scripts / "hash-editor-find-f2-artifact.py"
        target.write_bytes(target.read_bytes() + b"# tamper\n")
        result = subprocess.run(
            [
                str(scripts / "build-editor-find-f2-performance-gate.sh"),
                "Debug",
                str(self.root / "fresh-derived-data"),
            ],
            check=False,
            capture_output=True,
            text=True,
            cwd="/private/tmp",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("artifact hasher is not the pinned", result.stderr)

    def test_build_wrapper_rejects_hasher_symlink_and_fifo_before_read(self) -> None:
        scripts = self.copy_scripts()
        target = scripts / "hash-editor-find-f2-artifact.py"
        target.unlink()
        target.symlink_to(self.root / "missing-target")
        command = [
            str(scripts / "build-editor-find-f2-performance-gate.sh"),
            "Debug",
            str(self.root / "fresh-derived-data"),
        ]
        symlink_result = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            cwd="/private/tmp",
            timeout=2,
        )
        self.assertNotEqual(symlink_result.returncode, 0)
        self.assertIn("artifact hasher is not the pinned", symlink_result.stderr)

        target.unlink()
        os.mkfifo(target)
        fifo_result = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            cwd="/private/tmp",
            timeout=2,
        )
        self.assertNotEqual(fifo_result.returncode, 0)
        self.assertIn("artifact hasher is not the pinned", fifo_result.stderr)

    def test_external_inventory_rejects_tool_tamper(self) -> None:
        scripts = self.copy_scripts()
        target = scripts / "hash-editor-find-f2-artifact.py"
        target.write_bytes(target.read_bytes() + b"# tamper\n")
        result = subprocess.run(
            [str(scripts / "check-editor-find-f2-tooling-inventory.py")],
            check=False,
            capture_output=True,
            text=True,
            cwd="/private/tmp",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("hash mismatch", result.stderr)


if __name__ == "__main__":
    unittest.main()
