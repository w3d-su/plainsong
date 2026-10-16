"""Synthetic build artifacts exercise tooling gates, never product providers."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shlex
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.dont_write_bytecode = True
SCRIPTS = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), SCRIPTS / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


proof = load("ios-provenance")
packaging = load("ios-packaging")
results = load("ios-test-results")


class RunnerEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="plainsong-ios-runner-fixture-")
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
        self.archive = self.root / "Fixture.xcarchive"
        self.app = self.archive / "Products/Applications/PlainsongIOS.app"
        self.app.mkdir(parents=True)
        (self.app / "Info.plist").write_bytes(plistlib.dumps({"MinimumOSVersion": "26.0", "CFBundleExecutable": "PlainsongIOS"}))
        (self.app / "PlainsongIOS").write_bytes(b"synthetic artifact, not a Mach-O or install receipt")
        self.metadata = Path(str(self.archive) + "-meta")
        self.metadata.mkdir()
        proof.write_json(self.metadata / "source.json", proof.source_snapshot(self.repository))

    def git(self, *arguments):
        subprocess.run(["git", "-C", str(self.repository), *arguments], check=True, stdout=subprocess.DEVNULL)

    def record(self, result=0):
        # These cases test receipt/digest arbitration. Device-platform parsing
        # has independent negative tests; actual vtool is exercised by archive.
        with patch.object(proof, "verify_device_app"):
            proof.record_archive(self.archive, self.repository, result, "start", "end")

    def verify(self):
        with patch.object(proof, "verify_device_app"):
            return proof.verify_archive(self.archive, self.repository)

    def testSuccessfulReceiptRetainsExactSourceAndArtifactFingerprints(self):
        self.record()
        receipt = self.verify()
        self.assertEqual(receipt["archive_sha256"], proof.tree_digest(self.archive))
        self.assertEqual(receipt["source_fingerprint"], proof.source_snapshot(self.repository)["source_fingerprint"])

    def testFailedArchiveCannotBeRepackagedEvenWithAnExistingApp(self):
        self.record(result=65)
        with self.assertRaisesRegex(ValueError, "successful Release"):
            self.verify()

    def testArchiveReceiptFromAnotherContractCannotBeRepackaged(self):
        self.record()
        receipt_path = self.metadata / "archive.json"
        receipt = json.loads(receipt_path.read_text())
        receipt["contract_version"] = "unreviewed-contract"
        proof.write_json(receipt_path, receipt)
        with self.assertRaisesRegex(ValueError, "successful Release"):
            self.verify()

    def testMissingSuccessReceiptCannotBeRepackaged(self):
        with self.assertRaises(OSError):
            self.verify()

    def testDirtySourceDriftAtTheSameHeadRejectsArchiveReuse(self):
        self.record()
        (self.repository / "AppIOS/App.swift").write_text("// changed after archive\n")
        with self.assertRaisesRegex(ValueError, "fingerprint changed"):
            self.verify()

    def testUntrackedBuildInputDriftRejectsArchiveReuse(self):
        self.record()
        (self.repository / "AppIOS/New.swift").write_text("// new compiled input\n")
        with self.assertRaisesRegex(ValueError, "fingerprint changed"):
            self.verify()

    def testAcceptanceSourceDriftIsIncludedInInputFingerprint(self):
        directory = self.repository / "IOSAcceptanceTests/UI"
        directory.mkdir(parents=True)
        source = directory / "IOSAcceptanceLaunchSmokeTests.swift"
        source.write_text("// original acceptance input\n")
        proof.write_json(self.metadata / "source.json", proof.source_snapshot(self.repository))
        self.record()
        source.write_text("// changed acceptance input\n")
        with self.assertRaisesRegex(ValueError, "fingerprint changed"):
            self.verify()

    def testHostedTestSourceDriftIsIncludedInInputFingerprint(self):
        tests = self.repository / "AppIOSTests"
        tests.mkdir()
        source = tests / "ShellTests.swift"
        source.write_text("// original hosted test input\n")
        proof.write_json(self.metadata / "source.json", proof.source_snapshot(self.repository))
        self.record()
        source.write_text("// changed hosted test input\n")
        with self.assertRaisesRegex(ValueError, "fingerprint changed"):
            self.verify()

    def testRequiredValidationManifestDriftFailsSourceVerification(self):
        manifests = (
            "docs/ios/evidence/validation/required-hosted-smoke.txt",
            "docs/ios/evidence/validation/required-component-tests.txt",
        )
        validation = self.repository / "docs/ios/evidence/validation"
        validation.mkdir(parents=True)
        for relative in manifests:
            (self.repository / relative).write_text("Suite/requiredA\nSuite/requiredB\n")
        self.git("add", "docs/ios/evidence/validation")
        self.git("commit", "-qm", "Required validation manifests")
        for relative in manifests:
            with self.subTest(manifest=relative):
                for item in manifests:
                    (self.repository / item).write_text("Suite/requiredA\nSuite/requiredB\n")
                snapshot = proof.source_snapshot(self.repository)
                self.assertIn(relative, snapshot["files"])
                proof.write_json(self.metadata / "source.json", snapshot)
                self.record()
                (self.repository / relative).write_text("Suite/requiredA\n")
                with self.assertRaisesRegex(ValueError, "fingerprint changed"):
                    proof.verify_source(self.metadata / "source.json", self.repository)
                with self.assertRaisesRegex(ValueError, "fingerprint changed"):
                    self.verify()

    def testChangedHeadRejectsReuseEvenWhenCompiledInputsAreEqual(self):
        self.record()
        (self.repository / "README.md").write_text("receipt documentation\n")
        self.git("add", "README.md")
        self.git("commit", "-qm", "Documentation fixture")
        with self.assertRaisesRegex(ValueError, "head or input fingerprint"):
            self.verify()

    def testModifiedArchiveBytesRejectTheSuccessReceipt(self):
        self.record()
        (self.app / "PlainsongIOS").write_bytes(b"modified artifact")
        with self.assertRaisesRegex(ValueError, "archive/source digest"):
            self.verify()

    def testSymlinkEscapeCannotEnterArtifactDigest(self):
        (self.app / "escape").symlink_to(self.repository / "AppIOS/App.swift")
        with self.assertRaisesRegex(ValueError, "symlink escapes"):
            proof.tree_digest(self.archive)

    def testForgedFingerprintWithoutMatchingInputManifestIsRejected(self):
        self.record()
        source = json.loads((self.metadata / "source.json").read_text())
        source["files"]["AppIOS/App.swift"]["sha256"] = "0" * 64
        proof.write_json(self.metadata / "source.json", source)
        with self.assertRaisesRegex(ValueError, "fingerprint changed"):
            self.verify()

    def testExactDevicePlatformRejectsArm64Simulator(self):
        with self.assertRaisesRegex(ValueError, "never IOSSIMULATOR"):
            proof.require_device_platform("    platform IOSSIMULATOR\n", "arm64")
        proof.require_device_platform("    platform IOS\n", "arm64")
        for text, architectures in [("platform IOS\nplatform IOSSIMULATOR\n", "arm64"), ("platform IOS\n", "arm64 x86_64"), ("", "arm64")]:
            with self.assertRaises(ValueError):
                proof.require_device_platform(text, architectures)

    def staging(self):
        staging = self.root / "staging"
        app = staging / "Payload/PlainsongIOS.app"
        app.mkdir(parents=True)
        (app / "new.txt").write_text("new payload")
        return staging, app

    def testFreshZipDropsMembersFromAPreviousIPA(self):
        output = self.root / "App.ipa"
        with zipfile.ZipFile(output, "w") as zipped:
            zipped.writestr("Payload/PlainsongIOS.app/obsolete.txt", "old payload")
        staging, _ = self.staging()
        packaging.fresh_zip(staging, output)
        with zipfile.ZipFile(output) as zipped:
            self.assertNotIn("Payload/PlainsongIOS.app/obsolete.txt", zipped.namelist())
            self.assertEqual(zipped.read("Payload/PlainsongIOS.app/new.txt"), b"new payload")
            self.assertIsNone(zipped.testzip())

    def testFailedFinalValidationPreservesPreviouslyPublishedIPA(self):
        output = self.root / "App.ipa"
        output.write_bytes(b"previous published IPA")
        staging, _ = self.staging()
        def reject():
            raise ValueError("source changed before publication")
        with self.assertRaisesRegex(ValueError, "source changed"):
            packaging.fresh_zip(staging, output, before_publish=reject)
        self.assertEqual(output.read_bytes(), b"previous published IPA")
        self.assertEqual(list(self.root.glob(".ios-ipa-*")), [])

    def testSigningMaterialCannotBePublished(self):
        staging, app = self.staging()
        (app / "private.keychain").write_bytes(b"synthetic forbidden fixture")
        with self.assertRaisesRegex(ValueError, "signing material"):
            packaging.fresh_zip(staging, self.root / "App.ipa")

    def testSkippedFailedMissingAndMalformedCasesCannotBecomePass(self):
        def document(status="Passed", identifier="Suite/required()"):
            return {"testNodes": [{"nodeType": "Test Case", "nodeIdentifier": identifier, "result": status}]}
        self.assertEqual(results.validate_results(document(), {"Suite/required"})["passed"], 1)
        for invalid in [{}, {"testNodes": []}, document("Skipped"), document("Failed"), document("Unknown"), document(identifier="Suite/other()")]:
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                results.validate_results(invalid, {"Suite/required"})
        with self.assertRaises(ValueError):
            results.validate_results(document(), set())
        with self.assertRaises(ValueError):
            results.validate_results({"testNodes": document()["testNodes"] * 2}, {"Suite/required"})

    def testMalformedJSONCLIExitsNonzeroAndKeepsFailureReport(self):
        malformed = self.root / "malformed.json"
        malformed.write_text("{broken json")
        required = self.root / "required.txt"
        required.write_text("Suite/required\n")
        report = self.root / "report.json"
        result = subprocess.run([
            sys.executable, str(SCRIPTS / "ios-test-results.py"), str(malformed),
            "--required", str(required), "--report", str(report),
            "--names", str(self.root / "names.txt"),
        ], text=True, capture_output=True)
        self.assertEqual(result.returncode, 65)
        self.assertEqual(json.loads(report.read_text())["status"], "FAILED")

    def testOptionalSkippedCaseIsRecordedSeparatelyFromExecution(self):
        document = {"testNodes": [
            {"nodeType": "Test Case", "nodeIdentifier": "Suite/required()", "result": "Passed"},
            {"nodeType": "Test Case", "nodeIdentifier": "Suite/optional()", "result": "Skipped"},
        ]}
        report = results.validate_results(document, {"Suite/required"})
        self.assertEqual(report["executed"], 1)
        self.assertEqual(report["skipped"], 1)


class RunnerLockTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="plainsong-ios-lock-fixture-")
        self.addCleanup(self.temporary.cleanup)
        self.probe = Path(self.temporary.name) / "probe.sh"
        self.probe.write_text("#!/bin/bash\nset -euo pipefail\nsource " + shlex.quote(str(SCRIPTS / "ios-common.sh")) +
                              '\nios_lock_or_exec "$0" "$@"\n'
                              'if [ "${1:-}" = nested ]; then "$0" inner\n'
                              'elif [ "${1:-}" = fail75 ]; then echo entered; exit 75\n'
                              'elif [ "${1:-}" = fail65 ]; then echo entered; exit 65\n'
                              'else echo entered; fi\n')
        self.probe.chmod(0o700)
        self.environment = dict(os.environ, IOS_LOCK_WAIT_SECONDS="0")
        self.environment.pop("IOS_RUNNER_LOCK_OWNER", None)
        self.environment.pop("IOS_RUNNER_LOCK_HOLDER", None)

    def run_probe(self, *arguments, **extra):
        return subprocess.run([str(self.probe), *arguments], env=dict(self.environment, **extra),
                              text=True, capture_output=True, timeout=10)

    def testPublicLockedFlagIsRejectedWithoutExecutingPayload(self):
        result = self.run_probe("--locked")
        self.assertEqual(result.returncode, 64, result.stderr)
        self.assertNotIn("entered", result.stdout)

    def testForgedAncestorContextIsRejected(self):
        result = self.run_probe(IOS_RUNNER_LOCK_OWNER=str(os.getpid()), IOS_RUNNER_LOCK_HOLDER=str(os.getppid()))
        self.assertEqual(result.returncode, 64, result.stderr)
        self.assertNotIn("entered", result.stdout)

    def testLegitimateNestedOperationUsesOneCanonicalLock(self):
        result = self.run_probe("nested")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "entered")

    def testPayloadFailureStaysDistinctFromAdmission(self):
        for argument, code in (("fail65", 65), ("fail75", 75)):
            with self.subTest(argument=argument):
                result = self.run_probe(argument, IOS_LOCK_WAIT_SECONDS="30")
                self.assertEqual(result.returncode, code, result.stderr)
                self.assertEqual(result.stdout.strip(), "entered")
                self.assertNotIn("admission timeout", result.stderr)

    def testBusyLockAdmissionExits75WithoutRunningPayload(self):
        import os
        import signal
        import time
        lock = "/private/tmp/plainsong-xcodebuild-test.lock"
        probe = subprocess.run(["/usr/bin/lockf", "-k", "-t", "0", lock, "true"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        holder = None
        if probe.returncode == 0:
            holder = subprocess.Popen(
                ["/usr/bin/lockf", "-k", "-t", "0", lock, "sleep", "8"], start_new_session=True)
            held = False
            for _ in range(50):
                busy = subprocess.run(["/usr/bin/lockf", "-k", "-t", "0", lock, "true"],
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                if busy.returncode != 0:
                    held = True
                    break
                time.sleep(0.05)
            self.assertTrue(held, "canonical lock was not observed busy")
        try:
            result = self.run_probe()
            self.assertEqual(result.returncode, 75, result.stderr)
            self.assertIn("admission timeout", result.stderr)
            self.assertNotIn("entered", result.stdout)
        finally:
            if holder is not None:
                os.killpg(holder.pid, signal.SIGKILL)
                holder.wait(timeout=5)
                for _ in range(50):
                    released = subprocess.run(["/usr/bin/lockf", "-k", "-t", "0", lock, "true"],
                                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    if released.returncode == 0:
                        break
                    time.sleep(0.05)

    def testDefaultAdmissionWaitIs45Seconds(self):
        text = (SCRIPTS / "ios-common.sh").read_text()
        self.assertIn('IOS_LOCK_WAIT_SECONDS:-45', text)
        self.assertNotIn('IOS_LOCK_WAIT_SECONDS:-300', text)


if __name__ == "__main__":
    unittest.main()
