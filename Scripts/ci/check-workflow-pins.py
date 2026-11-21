#!/usr/bin/env python3
"""Refuses a workflow that runs code no commit in this repository pins.

A `uses:` reference must name a 40-character commit SHA: a tag such as `@v4`
can be moved to other code by whoever controls the action, and the release
workflow holds `contents: write` and the update signing key. A local action
(`./path`) is pinned by the checkout itself. Every actions/checkout step sets
`persist-credentials: false`, so the job token is not left in .git/config for
later steps (Scripts/ci/git-with-token.sh passes it per command). `brew install` takes whatever
Homebrew serves that day; Scripts/ci/install-xcodegen.sh pins by digest.

Usage: check-workflow-pins.py [workflow.yml ...]   (default: .github/workflows)
"""
import re
import sys
from pathlib import Path

USES = re.compile(r"^\s*(?:-\s*)?uses:\s*['\"]?([^'\"\s#]+)")
PINNED = re.compile(r"@[0-9a-f]{40}$")
CHECKOUT = re.compile(r"^actions/checkout@")
STEP = re.compile(r"^\s*-\s")
BREW = re.compile(r"\bbrew\s+(?:install|upgrade|tap)\b")


def problems(text, name="workflow"):
    """One message per unpinned reference in a workflow's text."""
    found = []
    lines = text.splitlines()
    for number, line in enumerate(lines, start=1):
        if line.lstrip().startswith("#"):
            continue
        match = USES.match(line)
        if match:
            reference = match.group(1)
            if not reference.startswith("./") and not PINNED.search(reference):
                found.append(f"{name}:{number}: `{reference}` is not pinned to a commit SHA")
            if CHECKOUT.match(reference):
                step = []
                for following in lines[number:]:
                    if STEP.match(following):
                        break
                    step.append(following.split("#", 1)[0].strip())
                if "persist-credentials: false" not in step:
                    found.append(f"{name}:{number}: the checkout does not set persist-credentials: false")
        if BREW.search(line.split("#", 1)[0]):
            found.append(f"{name}:{number}: Homebrew installs an unpinned tool")
    return found


def main(arguments):
    root = Path(__file__).resolve().parents[2]
    paths = [Path(argument) for argument in arguments]
    if not paths:
        directory = root / ".github" / "workflows"
        paths = sorted(list(directory.glob("*.yml")) + list(directory.glob("*.yaml")))
        if not paths:
            print("error: no workflows found in " + str(directory), file=sys.stderr)
            return 1
    found = []
    for path in paths:
        found += problems(path.read_text(), path.name)
    for problem in found:
        print("error: " + problem, file=sys.stderr)
    if not found:
        print(f"workflow pins ok: {len(paths)} workflows")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
