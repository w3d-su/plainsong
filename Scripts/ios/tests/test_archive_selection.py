#!/usr/bin/env python3
"""`select-archive` must skip leftovers that can never be repackaged."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
SCRIPTS = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), SCRIPTS / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


proof = load("ios-provenance")


class ArchiveSelectionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="plainsong-ios-select-fixture-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repository = self.root / "repository"
        self.repository.mkdir()
        (self.repository / "project.yml").write_text("name: Fixture\n")
        (self.repository / "AppIOS").mkdir()
        (self.repository / "AppIOS/App.swift").write_text("// synthetic build input\n")
        self.git("init", "-q")
        self.git("config", "user.name", "Tooling Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("add", ".")
        self.git("commit", "-qm", "Initial fixture")
        self.output = self.root / "output"
        self.output.mkdir()
        self.clock = 1_700_000_000

    def git(self, *arguments):
        subprocess.run(["git", "-C", str(self.repository), *arguments], check=True, stdout=subprocess.DEVNULL)

    def archive(self, name, result=0):
        """Record an archive attempt; each one is newer than the one before."""
        archive = self.output / name / "PlainsongIOS.xcarchive"
        app = archive / "Products/Applications/PlainsongIOS.app"
        app.mkdir(parents=True)
        (app / "Info.plist").write_bytes(plistlib.dumps({"MinimumOSVersion": "26.0", "CFBundleExecutable": "PlainsongIOS"}))
        (app / "PlainsongIOS").write_bytes(b"synthetic artifact")
        metadata = Path(str(archive) + "-meta")
        metadata.mkdir()
        proof.write_json(metadata / "source.json", proof.source_snapshot(self.repository))
        with patch.object(proof, "verify_device_app"):
            proof.record_archive(archive, self.repository, result, "start", "end")
        self.clock += 60
        os.utime(archive, (self.clock, self.clock))
        return archive

    def select(self):
        with patch.object(proof, "verify_device_app"):
            return proof.select_archive(self.output, self.repository)

    def testNewerFailedAttemptDoesNotHideTheSuccessfulArchive(self):
        good = self.archive("archive-attempt-1")
        self.archive("archive-attempt-2", result=65)
        self.assertEqual(self.select(), str(good.resolve()))

    def testOnlyFailedAttemptsSelectNothingSoTheRunnerRebuilds(self):
        self.archive("archive-attempt-1", result=65)
        self.assertEqual(self.select(), "")

    def testArchiveOfOtherInputsAtTheSameHeadSelectsNothing(self):
        self.archive("archive-attempt-1")
        (self.repository / "AppIOS/App.swift").write_text("// edited after the archive\n")
        self.assertEqual(self.select(), "")

    def testNewerArchiveOfOtherInputsDoesNotHideTheCurrentOne(self):
        (self.repository / "AppIOS/App.swift").write_text("// edited before either archive\n")
        good = self.archive("archive-attempt-1")
        (self.repository / "AppIOS/App.swift").write_text("// a different edit\n")
        self.archive("archive-attempt-2")
        (self.repository / "AppIOS/App.swift").write_text("// edited before either archive\n")
        self.assertEqual(self.select(), str(good.resolve()))

    def testUnreadableReceiptIsSkipped(self):
        good = self.archive("archive-attempt-1")
        broken = self.archive("archive-attempt-2")
        (Path(str(broken) + "-meta") / "archive.json").write_text("{ truncated")
        self.assertEqual(self.select(), str(good.resolve()))

    def testModifiedBytesOfTheSelectedArchiveStillFailLoudly(self):
        archive = self.archive("archive-attempt-1")
        (archive / "Products/Applications/PlainsongIOS.app/PlainsongIOS").write_bytes(b"modified artifact")
        with self.assertRaisesRegex(ValueError, "archive/source digest"):
            self.select()

    def testCLIPrintsNothingAndExitsZeroWhenOnlyAFailedAttemptRemains(self):
        self.archive("archive-attempt-1", result=65)
        result = subprocess.run(
            [sys.executable, str(SCRIPTS / "ios-provenance.py"), "select-archive", str(self.output),
             "--repository", str(self.repository)],
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "")


if __name__ == "__main__":
    unittest.main()
