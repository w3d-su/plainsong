#!/usr/bin/env python3
"""Verify the package guard before any platform-specific tool can run."""
import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
PACKAGER = ROOT / 'Scripts' / 'package-ipa.py'


class FixturePackagingTests(unittest.TestCase):
    def test_missing_fixture_is_rejected_before_archive_creation(self):
        self.assert_guard(None, 'M0 bundled fixture is missing')

    def test_mismatched_fixture_is_rejected_before_archive_creation(self):
        self.assert_guard(b'wrong fixture', 'M0 bundled fixture byte mismatch')

    def test_symlink_fixture_is_rejected_before_archive_creation(self):
        self.assert_guard('symlink', 'M0 bundled fixture is missing')

    def assert_guard(self, contents, expected):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            app = root / 'Probe.app'
            app.mkdir()
            fixture = app / 'm0.md'
            if contents == 'symlink':
                fixture.symlink_to(ROOT / 'Fixtures' / 'm0.md')
            elif contents is not None:
                fixture.write_bytes(contents)
            archive = root / 'must-not-exist.ipa'
            completed = subprocess.run([sys.executable, str(PACKAGER), str(app), str(archive)],
                                       text=True, capture_output=True)
            self.assertNotEqual(completed.returncode, 0)
            self.assertIn(expected, completed.stderr)
            self.assertFalse(archive.exists())
            self.assertFalse(archive.with_suffix('.json').exists())


if __name__ == '__main__':
    unittest.main()
