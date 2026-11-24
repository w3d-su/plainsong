# A pull request that changes only the root `.gitignore` is docs-only

The `changes` job classified a top-level `.gitignore` as code, so a pull request that only
changed ignore rules ran the hosted build and all four XCTest shards on the shared macOS
runners. No job reads that file. CI checks out tracked files only, and ignore rules apply
only to untracked ones. On 2026-11-24 a probe repository with an ignored Swift file showed
that SwiftLint 0.65.1 (the CI pin) and SwiftFormat 0.64.0 still lint the file and
XcodeGen still adds it to the project. SwiftFormat was the local Homebrew build; the CI pin,
0.62.1, was not probed. `Scripts/check-preview-webview-layering.py` does
not use git. A modified or added root `.gitignore` now counts as docs, like a top-level
`*.md` or `LICENSE`. Deleting it still runs the full suite, as for every deleted top-level
file, and a nested `.gitignore` still counts as code.

Alternatives: keep `.gitignore` as code (rejected: it holds the macOS build and test
jobs for a change no job can observe); treat every `.gitignore` at any depth as docs (rejected:
a nested one sits beside sources, and the evidence above covers only the root file and the
tools CI runs today).

Supersedes: `2026-10-20-docs-only-prs-skip-test-jobs.md`, only in adding `.gitignore` to
the top-level docs files.
