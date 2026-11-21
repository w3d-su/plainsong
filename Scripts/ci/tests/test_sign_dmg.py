"""The Developer ID release signs, notarizes, staples and assesses the DMG itself."""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "Scripts/sign-dmg.sh"
STUB = '#!/bin/bash\necho "{name} $*" >> "$STUB_LOG"\n[ "${{STUB_FAIL:-}}" = "{name} $1" ] && exit 9\nexit 0\n'
NOTARY = {"PLAINSONG_NOTARY_KEY_PATH": "/k.p8", "PLAINSONG_NOTARY_KEY_ID": "KID", "PLAINSONG_NOTARY_ISSUER": "ISS"}


class SignDMGTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.dmg = self.root / "Plainsong.dmg"
        self.dmg.write_bytes(b"dmg")
        self.log = self.root / "log"
        self.log.write_text("")
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        for name in ("codesign", "xcrun", "spctl"):
            (bin_dir / name).write_text(STUB.format(name=name))
            (bin_dir / name).chmod(0o755)
        self.env = {"PATH": f"{bin_dir}:/usr/bin:/bin", "STUB_LOG": str(self.log),
                    "PLAINSONG_SIGNING_IDENTITY": "Developer ID Application: Test"}

    def run_script(self, **extra):
        result = subprocess.run([str(SCRIPT), str(self.dmg)], env={**self.env, **extra},
                                capture_output=True, text=True)
        return result, self.log.read_text().splitlines()

    def test_signs_notarizes_staples_and_assesses_the_dmg(self):
        result, calls = self.run_script(**NOTARY)
        self.assertEqual(result.returncode, 0, result.stderr)
        dmg = str(self.dmg)
        self.assertEqual(calls, [
            f"codesign --force --sign Developer ID Application: Test --timestamp {dmg}",
            f"codesign --verify --strict --verbose=2 {dmg}",
            f"xcrun notarytool submit {dmg} --key /k.p8 --key-id KID --issuer ISS --wait",
            f"xcrun stapler staple {dmg}",
            f"xcrun stapler validate {dmg}",
            f"spctl --assess --type open --context context:primary-signature --verbose=2 {dmg}",
        ])

    def test_a_failed_step_fails_the_release(self):
        for failing in ("codesign --force", "xcrun notarytool", "spctl --assess"):
            self.log.write_text("")
            result, _ = self.run_script(STUB_FAIL=failing, **NOTARY)
            self.assertNotEqual(result.returncode, 0, failing)

    def test_skip_notarize_still_signs(self):
        result, calls = self.run_script(PLAINSONG_SKIP_NOTARIZE="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call.split()[0] for call in calls], ["codesign", "codesign"])

    def test_notarization_needs_its_credentials(self):
        result, calls = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("xcrun", " ".join(calls))

    def test_signing_needs_an_identity(self):
        del self.env["PLAINSONG_SIGNING_IDENTITY"]
        result, calls = self.run_script(**NOTARY)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])

    def test_release_signs_the_dmg_before_the_checksum(self):
        release = (ROOT / "Scripts/release.sh").read_text()
        package = release.index('Scripts/make-dmg.sh "$APP_PATH" "$DMG_PATH"')
        sign = release.index('Scripts/sign-dmg.sh "$DMG_PATH"')
        self.assertLess(package, sign)
        self.assertLess(sign, release.index("shasum -a 256"))
        self.assertIn('if [[ "$UNSIGNED" != "1" ]]; then\n    Scripts/sign-dmg.sh', release)


if __name__ == "__main__":
    unittest.main()
