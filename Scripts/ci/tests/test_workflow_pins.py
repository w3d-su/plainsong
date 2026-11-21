"""Workflows run only code a commit pins (review High #49)."""
import importlib.util
import subprocess
import sys
import unittest
from pathlib import Path

CI = Path(__file__).resolve().parents[1]
REPOSITORY = CI.parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), CI / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


pins = load("check-workflow-pins")
SHA = "11d5960a326750d5838078e36cf38b85af677262"


class WorkflowPinTests(unittest.TestCase):
    def testEveryWorkflowInTheRepositoryIsPinned(self):
        result = subprocess.run([sys.executable, str(CI / "check-workflow-pins.py")],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def testAMovableTagIsRefused(self):
        for reference in ("actions/cache@v4", "actions/cache@v4.3.0", "actions/cache@main",
                          "github/codeql-action/init@v4", "actions/cache@" + SHA[:12], "actions/cache"):
            for line in (f"      - uses: {reference}", f"        uses: {reference}  # v4",
                         f'      - uses: "{reference}"'):
                self.assertEqual(len(pins.problems(line)), 1, line)

    def testACommitShaAndALocalActionPass(self):
        text = (f"      - uses: actions/checkout@{SHA} # v4.4.0\n"
                "        with:\n          persist-credentials: false\n"
                f"        uses: github/codeql-action/init@{SHA}\n"
                "      - uses: ./.github/actions/setup\n"
                "      # uses: actions/checkout@v4\n")
        self.assertEqual(pins.problems(text), [])

    def testACheckoutThatKeepsTheTokenIsRefused(self):
        checkout = f"      - uses: actions/checkout@{SHA}\n"
        kept = [checkout,
                checkout + "        with:\n          fetch-depth: 0\n",
                checkout + "        with:\n          persist-credentials: true\n",
                checkout + "        with:\n          # persist-credentials: false\n          fetch-depth: 2\n",
                checkout + "      - name: next\n        with:\n          persist-credentials: false\n"]
        for text in kept:
            self.assertEqual(len(pins.problems(text)), 1, text)
        dropped = checkout + "        if: ${{ always() }}\n        with:\n          fetch-depth: 2\n          persist-credentials: false\n"
        self.assertEqual(pins.problems(dropped), [])

    def testGitWithTokenKeepsTheTokenOutOfConfigAndArguments(self):
        import os
        import tempfile
        with tempfile.TemporaryDirectory() as temporary:
            subprocess.run(["git", "init", "--quiet", temporary], check=True)
            environment = dict(os.environ, GH_TOKEN="secret-token-value")
            shown = subprocess.run([str(CI / "git-with-token.sh"), "-C", temporary, "config", "--show-origin",
                                    "--get", "http.https://github.com/.extraheader"],
                                   capture_output=True, text=True, env=environment)
            self.assertEqual(shown.returncode, 0, shown.stderr)
            self.assertTrue(shown.stdout.startswith("command line:"), shown.stdout)
            self.assertIn("AUTHORIZATION: basic eC1hY2Nlc3MtdG9rZW46c2VjcmV0LXRva2VuLXZhbHVl", shown.stdout)
            self.assertNotIn("secret-token-value", (Path(temporary) / ".git" / "config").read_text())
            self.assertNotIn("eC1hY2Nlc3M", (Path(temporary) / ".git" / "config").read_text())
            del environment["GH_TOKEN"]
            missing = subprocess.run([str(CI / "git-with-token.sh"), "-C", temporary, "status"],
                                     capture_output=True, text=True, env=environment)
            self.assertNotEqual(missing.returncode, 0)

    def testHomebrewInstallIsRefused(self):
        self.assertEqual(len(pins.problems("        run: brew install xcodegen")), 1)
        self.assertEqual(len(pins.problems("          brew install xcodegen swiftlint")), 1)
        self.assertEqual(pins.problems("  # pinned instead of `brew install`"), [])
        self.assertEqual(pins.problems("        run: Scripts/ci/install-xcodegen.sh  # not brew install"), [])

    def testTheCommandFailsOnAnUnpinnedWorkflow(self):
        import tempfile
        with tempfile.TemporaryDirectory() as temporary:
            workflow = Path(temporary) / "bad.yml"
            workflow.write_text("jobs:\n  a:\n    steps:\n      - uses: actions/cache@v4\n")
            result = subprocess.run([sys.executable, str(CI / "check-workflow-pins.py"), str(workflow)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("bad.yml:4", result.stderr)

    def testTheXcodeGenInstallerPinsADigest(self):
        script = (CI / "install-xcodegen.sh").read_text()
        self.assertRegex(script, r'XCODEGEN_SHA256="[0-9a-f]{64}"')
        self.assertIn("shasum -a 256 -c", script)


if __name__ == "__main__":
    unittest.main()
