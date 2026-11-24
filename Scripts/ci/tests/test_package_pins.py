"""The generated project builds only the committed package revisions (review High #47)."""
import json
import os
import re
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

REPOSITORY = Path(__file__).resolve().parents[3]
RESOLVED = REPOSITORY / "Package.resolved"
INSTALLED = Path("Plainsong.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
FLAG = "-onlyUsePackageVersionsFromResolvedFile"
URL = re.compile(r"https://github\.com/[\w.-]+/[\w.-]+")


def identity(url):
    name = url.rstrip("/").rsplit("/", 1)[1].lower()
    return name[:-4] if name.endswith(".git") else name


def pins(path):
    return {pin["identity"]: pin["state"] for pin in json.loads(Path(path).read_text())["pins"]}


class PackagePinTests(unittest.TestCase):
    def testEveryPinNamesARevision(self):
        root = pins(RESOLVED)
        self.assertTrue(root)
        for name, state in root.items():
            self.assertRegex(state.get("revision", ""), r"^[0-9a-f]{40}$", name)

    def testEveryRemotePackageTheProjectNamesIsPinned(self):
        root = pins(RESOLVED)
        manifests = [REPOSITORY / "project.yml", *sorted((REPOSITORY / "Packages").glob("*/Package.swift"))]
        named = set()
        for manifest in manifests:
            for line in manifest.read_text().splitlines():
                if re.search(r"\burl:", line):
                    named.update(identity(url) for url in URL.findall(line))
        self.assertIn("yams", named)
        self.assertIn("sparkle", named)
        self.assertEqual(sorted(named - set(root)), [])

    def testThePackagePinsAgreeWithTheProjectPins(self):
        root = pins(RESOLVED)
        for path in sorted((REPOSITORY / "Packages").glob("*/Package.resolved")):
            for name, state in pins(path).items():
                self.assertEqual(state["revision"], root.get(name, {}).get("revision"),
                                 f"{path.relative_to(REPOSITORY)}: {name}")

    def testSparkleStaysAtTheRevisionProjectYmlNames(self):
        revision = re.search(r"Sparkle:\n(?:.*\n){1,4}?\s+revision: ([0-9a-f]{40})",
                             (REPOSITORY / "project.yml").read_text()).group(1)
        self.assertEqual(pins(RESOLVED)["sparkle"]["revision"], revision)

    def generate(self, root, with_pins):
        tools = root / "tools"
        tools.mkdir()
        stub = tools / "xcodegen"
        stub.write_text("#!/bin/bash\nmkdir -p Plainsong.xcodeproj\n")
        stub.chmod(stub.stat().st_mode | stat.S_IXUSR)
        project = root / "project"
        project.mkdir()
        if with_pins:
            (project / "Package.resolved").write_bytes(RESOLVED.read_bytes())
        environment = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}")
        result = subprocess.run([str(REPOSITORY / "Scripts" / "generate-project.sh"), str(project)],
                                capture_output=True, text=True, env=environment)
        return project, result

    def testGenerateInstallsThePinsIntoTheProject(self):
        with tempfile.TemporaryDirectory() as temporary:
            project, result = self.generate(Path(temporary), with_pins=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((project / INSTALLED).read_bytes(), RESOLVED.read_bytes())

    def testGenerateRefusesARepositoryWithoutPins(self):
        with tempfile.TemporaryDirectory() as temporary:
            project, result = self.generate(Path(temporary), with_pins=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((project / "Plainsong.xcodeproj").exists())

    def testNothingGeneratesTheProjectWithoutThePins(self):
        callers = ["Makefile", "Scripts/release.sh", "Scripts/ios/run-ios-archive.sh",
                   "Scripts/ios/run-ios-build.sh", "Scripts/ios/run-ios-tests.sh"]
        for caller in callers:
            text = (REPOSITORY / caller).read_text()
            self.assertIn("Scripts/generate-project.sh", text, caller)
            self.assertNotRegex(text, r"(?m)^\s*xcodegen generate\b", caller)

    def testShippedAndHostedBuildsRefuseToResolve(self):
        for caller in ("Scripts/release.sh", "Scripts/ios/run-ios-archive.sh", "Scripts/run-hosted-tests.sh"):
            self.assertIn(FLAG, (REPOSITORY / caller).read_text(), caller)


if __name__ == "__main__":
    unittest.main()
