"""Positive and negative fixtures for acceptance admission. No product providers."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import textwrap
import unittest

sys.dont_write_bytecode = True
SCRIPTS = Path(__file__).resolve().parents[1]


def load(name):
    import importlib.util
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), SCRIPTS / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


admission = load("ios-test-admission")
resources = load("ios-resource-preflight")
components = load("ios-component-results")


class AdmissionFixtures(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="plainsong-ios-admission-")
        self.addCleanup(self.temporary.cleanup)
        self.derived = Path(self.temporary.name) / "dd"
        self.products = self.derived / "Build" / "Products"
        self.products.mkdir(parents=True)
        self.report = Path(self.temporary.name) / "admission.json"

    def macho(self, path):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"\xcf\xfa\xed\xfe" + b"\0" * 32)

    def bundle(self, name):
        bundle = self.products / "Debug-iphonesimulator" / (name + ".xctest")
        self.macho(bundle / name)
        (bundle / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": name}))
        return bundle

    def plan(self, scheme, targets, filename=None):
        path = self.products / (filename or (scheme + ".xctestrun"))
        path.write_bytes(plistlib.dumps({
            "ContainerInfo": {"SchemeName": scheme},
            "TestConfigurations": [{
                "IsEnabled": True,
                "Name": "Test Scheme Action",
                "TestTargets": targets,
            }],
        }))
        return path

    def target(self, name, bundle):
        root = str(self.products)
        return {
            "BlueprintName": name,
            "IsEnabled": True,
            "TestBundlePath": "__TESTROOT__/Debug-iphonesimulator/" + bundle,
            "TestHostPath": "__TESTROOT__/Debug-iphonesimulator/PlainsongIOS.app",
        }

    def admit(self, scheme):
        result = subprocess.run([
            sys.executable, str(SCRIPTS / "ios-test-admission.py"),
            "--derived-data", str(self.derived), "--scheme", scheme, "--report", str(self.report),
        ], text=True, capture_output=True)
        body = json.loads(self.report.read_text())
        return result, body

    def testEnabledMachOImageIsCompiled(self):
        self.bundle("IOSAcceptanceUITests")
        app = self.products / "Debug-iphonesimulator" / "PlainsongIOS.app"
        self.macho(app / "PlainsongIOS")
        (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "PlainsongIOS"}))
        (self.products / "libHarness.a").write_bytes(b"\xcf\xfa\xed\xfe" + b"library")
        self.plan("IOSAcceptance", [self.target("IOSAcceptanceUITests", "IOSAcceptanceUITests.xctest")])
        result, body = self.admit("IOSAcceptance")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(body["tests_compiled"])
        self.assertEqual(body["compiled_test_images"], 1)
        self.assertEqual(body["images"][0]["bundle"], "IOSAcceptanceUITests.xctest")
        self.assertEqual(body["library_products_ignored"], ["libHarness.a"])

    def testEmptyPlanIsNotTestsCompiled(self):
        (self.products / "libOnly.a").write_bytes(b"not an xctest")
        (self.products / "PreviewKit.xctestrun").write_bytes(plistlib.dumps({
            "ContainerInfo": {"SchemeName": "PreviewKit"},
            "TestConfigurations": [],
        }))
        result, body = self.admit("PreviewKit")
        self.assertEqual(result.returncode, 65, result.stderr)
        self.assertFalse(body["tests_compiled"])
        self.assertEqual(body["compiled_test_images"], 0)
        self.assertIn("not tests compiled", body["reason"])
        self.assertNotIn("libOnly.a", json.dumps(body["images"]))

    def testDisabledTargetAndMissingImageFail(self):
        self.bundle("IOSAcceptanceUITests")
        app = self.products / "Debug-iphonesimulator" / "PlainsongIOS.app"
        self.macho(app / "PlainsongIOS")
        target = self.target("IOSAcceptanceUITests", "IOSAcceptanceUITests.xctest")
        target["IsEnabled"] = False
        self.plan("IOSAcceptance", [target])
        result, body = self.admit("IOSAcceptance")
        self.assertEqual(result.returncode, 65, result.stderr)
        self.assertFalse(body["tests_compiled"])

    def testBundleOutsideDerivedDataIsRejected(self):
        outside = Path(self.temporary.name) / "escape.xctest"
        self.macho(outside / "escape")
        (outside / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "escape"}))
        app = self.products / "Debug-iphonesimulator" / "PlainsongIOS.app"
        self.macho(app / "PlainsongIOS")
        (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "PlainsongIOS"}))
        self.plan("IOSAcceptance", [{
            "BlueprintName": "IOSAcceptanceUITests",
            "TestBundlePath": str(outside),
            "TestHostPath": "__TESTROOT__/Debug-iphonesimulator/PlainsongIOS.app",
        }])
        result, body = self.admit("IOSAcceptance")
        self.assertEqual(result.returncode, 65, result.stderr)
        self.assertFalse(body["tests_compiled"])
        self.assertIn("escapes", body["reason"])

    def testFormat1PlanUsesMetadataSchemeAndBuiltImages(self):
        runner = self.products / "Debug-iphonesimulator" / "IOSAcceptanceUITests-Runner.app"
        self.macho(runner / "IOSAcceptanceUITests-Runner")
        (runner / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "IOSAcceptanceUITests-Runner"}))
        bundle = runner / "PlugIns" / "IOSAcceptanceUITests.xctest"
        self.macho(bundle / "IOSAcceptanceUITests")
        (bundle / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "IOSAcceptanceUITests"}))
        app = self.products / "Debug-iphonesimulator" / "PlainsongIOS.app"
        self.macho(app / "PlainsongIOS")
        (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "PlainsongIOS"}))
        path = self.products / "IOSAcceptance_iphonesimulator.xctestrun"
        path.write_bytes(plistlib.dumps({
            "__xctestrun_metadata__": {"ContainerInfo": {"SchemeName": "IOSAcceptance"}, "FormatVersion": 1},
            "IOSAcceptanceUITests": {
                "BlueprintName": "IOSAcceptanceUITests",
                "IsUITestBundle": True,
                "TestBundlePath": "__TESTHOST__/PlugIns/IOSAcceptanceUITests.xctest",
                "TestHostPath": "__TESTROOT__/Debug-iphonesimulator/IOSAcceptanceUITests-Runner.app",
                "UITargetAppPath": "__TESTROOT__/Debug-iphonesimulator/PlainsongIOS.app",
            },
        }))
        result, body = self.admit("IOSAcceptance")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(body["compiled_test_images"], 1)
        self.assertEqual(body["xctestrun"], "IOSAcceptance_iphonesimulator.xctestrun")

    def testOtherSchemeDoesNotSatisfyTheRequestedPlan(self):
        self.bundle("PreviewKitTests")
        self.plan("PreviewKit-Package", [{
            "BlueprintName": "PreviewKitTests",
            "TestBundlePath": "__TESTROOT__/Debug-iphonesimulator/PreviewKitTests.xctest",
            "TestHostPath": "__PLATFORMS__/xctest",
        }])
        result, body = self.admit("IOSAcceptance")
        self.assertEqual(result.returncode, 65, result.stderr)
        self.assertFalse(body["tests_compiled"])
        self.assertIn("found 0", body["reason"])


class ResourceAndComponentFixtures(unittest.TestCase):
    def testEmptyResourceManifestFailsClosed(self):
        temporary = tempfile.TemporaryDirectory(prefix="plainsong-ios-resources-")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        manifest = root / "empty.txt"
        manifest.write_text("# nothing\n\n")
        bundle = root / "App.app"
        bundle.mkdir()
        report = root / "resources.json"
        result = subprocess.run([
            sys.executable, str(SCRIPTS / "ios-resource-preflight.py"),
            "--manifest", str(manifest), "--root", str(bundle),
            "--parity", str(root / "preview") + ":preview", "--report", str(report),
        ], text=True, capture_output=True)
        self.assertEqual(result.returncode, 65, result.stderr)
        self.assertIn("no entries", result.stderr)

    def testParityMismatchFailsAndMatchPasses(self):
        temporary = tempfile.TemporaryDirectory(prefix="plainsong-ios-parity-")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        source = root / "preview"
        source.mkdir()
        (source / "index.html").write_text("preview")
        bundle = root / "App.app"
        bundled = bundle / "preview"
        bundled.mkdir(parents=True)
        (bundled / "index.html").write_text("tampered")
        manifest = root / "manifest.txt"
        manifest.write_text("preview/index.html\n")
        report = root / "bad.json"
        result = subprocess.run([
            sys.executable, str(SCRIPTS / "ios-resource-preflight.py"),
            "--manifest", str(manifest), "--root", str(bundle),
            "--parity", str(source) + ":preview", "--report", str(report),
        ], text=True, capture_output=True)
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertIn("sha256 differs", report.read_text())
        (bundled / "index.html").write_text("preview")
        good = root / "good.json"
        result = subprocess.run([
            sys.executable, str(SCRIPTS / "ios-resource-preflight.py"),
            "--manifest", str(manifest), "--root", str(bundle),
            "--parity", str(source) + ":preview", "--report", str(good),
        ], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(good.read_text())["missing"], [])

    def testComponentLogRequiresNamedPasses(self):
        temporary = tempfile.TemporaryDirectory(prefix="plainsong-ios-components-")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        required = root / "required.txt"
        required.write_text("BoundedWaitTests/testTimeoutStaysFailed\n")
        log = root / "swift-test.log"
        log.write_text(textwrap.dedent("""\
            Build complete! (1.00 sec)
            Test Case '-[IOSAcceptanceHarnessTests.BoundedWaitTests testTimeoutStaysFailed]' passed (0.001 seconds).
        """))
        report = root / "gate.json"
        result = subprocess.run([
            sys.executable, str(SCRIPTS / "ios-component-results.py"), str(log),
            "--required", str(required), "--report", str(report), "--names", str(root / "names.txt"),
        ], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(report.read_text())["result_format"], "swift-test-xctest-log")
        log.write_text("Build complete! (1.00 sec)\n")
        result = subprocess.run([
            sys.executable, str(SCRIPTS / "ios-component-results.py"), str(log),
            "--required", str(required), "--report", str(report), "--names", str(root / "names.txt"),
        ], text=True, capture_output=True)
        self.assertEqual(result.returncode, 65, result.stderr)
        self.assertEqual(json.loads(report.read_text())["status"], "FAILED")

    def testPreviewSchemeIsRejectedBeforeLock(self):
        env = dict(os.environ)
        env.pop("IOS_RUNNER_LOCK_OWNER", None)
        env.pop("IOS_RUNNER_LOCK_HOLDER", None)
        env["IOS_SCHEME"] = "PreviewKit"
        env["IOS_LOCK_WAIT_SECONDS"] = "0"
        result = subprocess.run([str(SCRIPTS / "run-ios-tests.sh")], env=env,
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 64, result.stderr)
        self.assertIn("PreviewKit-Package", result.stderr)


if __name__ == "__main__":
    unittest.main()
