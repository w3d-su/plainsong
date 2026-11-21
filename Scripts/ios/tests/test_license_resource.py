#!/usr/bin/env python3
"""The iOS app ships the GPL text, and the archive gate refuses one without it."""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
SCRIPTS = Path(__file__).resolve().parents[1]
REPOSITORY = SCRIPTS.parents[1]
MANIFEST = SCRIPTS / "required-app-resources.txt"


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), SCRIPTS / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


preflight = load("ios-resource-preflight")


class LicenseResourceTests(unittest.TestCase):
    def testRequiredResourceManifestNamesTheLicense(self):
        self.assertIn("LICENSE", preflight.manifest_entries(MANIFEST))

    def testPreflightRefusesAnAppWithoutTheLicense(self):
        with tempfile.TemporaryDirectory(prefix="plainsong-ios-license-fixture-") as temporary:
            app = Path(temporary) / "PlainsongIOS.app"
            for relative in preflight.manifest_entries(MANIFEST):
                path = app / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("fixture\n")
            command = [sys.executable, str(SCRIPTS / "ios-resource-preflight.py"),
                       "--manifest", str(MANIFEST), "--root", str(app),
                       "--report", str(Path(temporary) / "resources.json")]
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 0)
            (app / "LICENSE").unlink()
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 3)

    @unittest.skipUnless(shutil.which("xcodegen"), "xcodegen resolves project.yml")
    def testEveryAppTargetBundlesTheLicense(self):
        dump = subprocess.run(["xcodegen", "dump", "--type", "json", "--spec", str(REPOSITORY / "project.yml")],
                              capture_output=True, text=True, check=True)
        targets = json.loads(dump.stdout)["targets"]
        for name in ("Plainsong", "PlainsongIOS"):
            sources = [source for source in targets[name]["sources"] if isinstance(source, dict)]
            licenses = [source for source in sources if source.get("path") == "LICENSE"]
            self.assertEqual([source.get("buildPhase") for source in licenses], ["resources"], name)


if __name__ == "__main__":
    unittest.main()
