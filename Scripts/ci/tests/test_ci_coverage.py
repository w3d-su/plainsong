"""CI runs the checks that used to be skipped or left to release time."""
import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
CI = (ROOT / ".github/workflows/ci.yml").read_text()
MAKEFILE = (ROOT / "Makefile").read_text()


def target_body(name):
    match = re.search(rf"^{re.escape(name)}:.*\n((?:\t.*\n)+)", MAKEFILE, re.M)
    return match.group(1) if match else ""


class CICoverageTests(unittest.TestCase):
    def test_pull_request_ci_runs_tooling_and_bundle_checks(self):
        for command in ("make test-ci-tooling", "make test-ios-tooling", "make check-preview-bundle",
                        "Scripts/make-appcast.sh --self-test"):
            self.assertIn(command, CI)

    def test_hosted_runs_start_the_export_request_recorder(self):
        script = (ROOT / "Scripts/run-hosted-tests.sh").read_text()
        self.assertIn("export_html_network_proxy.py", script)
        self.assertIn("export TEST_RUNNER_PLAINSONG_EXPORT_TEST_PROXY_PORT", script)

    def test_preview_bundle_check_rebuilds_and_fails_on_a_difference(self):
        self.assertRegex(MAKEFILE, r"(?m)^check-preview-bundle: preview-bundle$")
        body = target_body("check-preview-bundle")
        self.assertIn("git status --porcelain -- App/Resources/preview", body)
        self.assertIn("exit 1", body)

    def test_every_phony_target_has_a_rule(self):
        phony = {name for line in re.findall(r"(?m)^\.PHONY:(.*)$", MAKEFILE) for name in line.split()}
        rules = set(re.findall(r"(?m)^([A-Za-z0-9_.-]+):", MAKEFILE))
        self.assertEqual(phony - rules, set())

    def test_clean_removes_every_package_and_the_release_directory(self):
        body = target_body("clean")
        for path in ("Plainsong.xcodeproj", "build", "Packages/*/.build", "Packages/*/build"):
            self.assertIn(path, body.split())

    def assert_ignored(self, *paths):
        for path in paths:
            ignored = subprocess.run(["git", "check-ignore", "-q", path], cwd=ROOT)
            self.assertEqual(ignored.returncode, 0, path)

    def test_python_caches_are_ignored(self):
        self.assert_ignored("Scripts/ios/__pycache__/x.cpython-312.pyc", "Scripts/ci/tests/__pycache__/")

    # Claude Code loads CLAUDE.local.md from subdirectories too, so the rule must
    # match at any depth, not only at the root.
    def test_local_agent_instructions_are_ignored_at_any_depth(self):
        self.assert_ignored("CLAUDE.local.md", "Packages/EditorKit/CLAUDE.local.md")


if __name__ == "__main__":
    unittest.main()
