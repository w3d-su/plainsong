"""The publish workflow fails closed and keeps the token off disk (review High #50)."""
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

CI = Path(__file__).resolve().parents[1]
WORKFLOW = CI.parents[1] / ".github" / "workflows" / "publish-appcast.yml"
REPOSITORY = "w3d-su/plainsong"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def git(*arguments, cwd=None):
    environment = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.com",
                       GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.com")
    subprocess.run(["git", *arguments], cwd=cwd, check=True, capture_output=True, env=environment)


def feed(*entries):
    """entries: (build, tag, channel, signature)"""
    body = ""
    for build, tag, channel, signature in entries:
        signed = f' sparkle:edSignature="{signature}"' if signature is not None else ""
        body += (f"<item><sparkle:version>{build}</sparkle:version>"
                 + (f"<sparkle:channel>{channel}</sparkle:channel>" if channel else "")
                 + f'<enclosure url="https://github.com/{REPOSITORY}/releases/download/{tag}/Plainsong.dmg"'
                 + f"{signed}/></item>")
    return f'<rss xmlns:sparkle="{SPARKLE}"><channel>{body}</channel></rss>'


class PagesCheckoutTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.remote = self.root / "remote.git"
        seed = self.root / "seed"
        git("init", "--quiet", "--bare", str(self.remote))
        git("init", "--quiet", str(seed))
        (seed / "readme").write_text("main\n")
        git("add", "readme", cwd=seed)
        git("commit", "--quiet", "-m", "main", cwd=seed)
        git("push", "--quiet", str(self.remote), "HEAD:refs/heads/main", cwd=seed)
        self.seed = seed

    def checkout(self, remote):
        environment = {key: value for key, value in os.environ.items() if key != "GH_TOKEN"}
        return subprocess.run([str(CI / "checkout-pages-branch.sh"), str(self.root / "pages"), str(remote)],
                              capture_output=True, text=True, env=environment)

    def branch(self):
        return subprocess.run(["git", "-C", str(self.root / "pages"), "symbolic-ref", "--short", "HEAD"],
                              capture_output=True, text=True).stdout.strip()

    def testThePublishedBranchIsCheckedOut(self):
        (self.seed / "appcast.xml").write_text(feed((300, "v1", "", "sig")))
        git("add", "appcast.xml", cwd=self.seed)
        git("commit", "--quiet", "-m", "feed", cwd=self.seed)
        git("push", "--quiet", str(self.remote), "HEAD:refs/heads/gh-pages", cwd=self.seed)
        result = self.checkout(self.remote)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.branch(), "gh-pages")
        self.assertTrue((self.root / "pages" / "appcast.xml").exists())

    def testAReachableRemoteWithoutTheBranchStartsIt(self):
        result = self.checkout(self.remote)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.branch(), "gh-pages")
        self.assertFalse((self.root / "pages" / "appcast.xml").exists())

    def testAnUnreachableRemoteStopsInsteadOfStartingAnEmptyBranch(self):
        result = self.checkout(self.root / "missing.git")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("not publishing", result.stderr)
        self.assertNotEqual(self.branch(), "gh-pages")

    def testTheWorkflowKeepsTheTokenOutOfTheRemoteUrl(self):
        text = WORKFLOW.read_text()
        self.assertNotIn("x-access-token", text)
        self.assertNotIn("@github.com", text)
        self.assertNotIn("--orphan", text)
        self.assertIn("Scripts/ci/checkout-pages-branch.sh pages", text)
        self.assertIn("git-with-token.sh\" push", text)


class FeedCheckTests(unittest.TestCase):
    def check(self, new, published=None, tag="v2"):
        with tempfile.TemporaryDirectory() as temporary:
            new_path, published_path = Path(temporary) / "new.xml", Path(temporary) / "published.xml"
            new_path.write_text(new)
            if published is not None:
                published_path.write_text(published)
            return subprocess.run([sys.executable, str(CI / "check-appcast-feed.py"), str(new_path),
                                   str(published_path), tag, REPOSITORY], capture_output=True, text=True)

    def testASignedNewerFeedPasses(self):
        result = self.check(feed((300, "v1", "", "a"), (301, "v2", "", "b")), feed((300, "v1", "", "a")))
        self.assertEqual(result.returncode, 0, result.stderr)

    def testTheFirstFeedPasses(self):
        self.assertEqual(self.check(feed((301, "v2", "", "b"))).returncode, 0)

    def testAnUnsignedDownloadForTheTagIsRefused(self):
        for signature in (None, "", "  "):
            result = self.check(feed((300, "v1", "", "a"), (301, "v2", "", signature)), feed((300, "v1", "", "a")))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("no sparkle:edSignature", result.stderr)

    def testAnOlderFeedIsRefused(self):
        result = self.check(feed((300, "v2", "", "a")), feed((301, "v3", "", "b")))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already has build 301", result.stderr)

    def testAFeedThatDropsAChannelIsRefused(self):
        result = self.check(feed((302, "v2", "beta", "c")), feed((301, "v1", "", "b")))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("default channel", result.stderr)

    def testADownloadOutsideTheRepositoryIsRefused(self):
        new = feed((301, "v2", "", "b")).replace("</channel>",
            f'<item><sparkle:version>302</sparkle:version><enclosure url="https://example.com/x.dmg" '
            f'sparkle:edSignature="c"/></item></channel>')
        self.assertIn("outside this repository", self.check(new).stderr)

    def testAFeedWithoutTheTagIsRefused(self):
        self.assertIn("no item downloads from", self.check(feed((301, "v1", "", "b"))).stderr)


if __name__ == "__main__":
    unittest.main()
