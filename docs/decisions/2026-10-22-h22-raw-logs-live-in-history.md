# The H22 paired-evidence raw logs leave the tree; their JSON summaries stay

`docs/evidence` was 37.6 MiB of the 63.7 MiB tracked tree, and almost all of it was raw
`xcodebuild` output in two directories: `h22-e9-paired-20261004` (100 logs) and
`h22-paired-20261004` (66 logs plus one 232 KiB `sample` capture). Every working tree,
worktree and shallow CI checkout paid for them (full clones still carry the blobs in
history), and no test, script or document reads them: `docs/perf-log.md` cited
the directories only as "where the raw logs are". Owner decision: delete the raw logs,
keep every JSON and JSONL summary (per-batch status, admission checks, start/end
snapshots, xcresult paths), and point `docs/perf-log.md` at commit
`d666e64f7907c9d10b9e3037957141b0ea4b1caf`, which holds both directories exactly as they
were on `main`. A reader recovers any log with `git show <sha>:<path>`. The log paths in the
summaries (and the 19 log SHA-256 values in `h22-log-whitespace-normalization-20261004.json`)
still name the removed files at that commit. `docs/evidence` is now 2.1 MiB and the
tracked tree 28.2 MiB. `editor-find-f2-c871ddf-retained-pack` is unchanged because
`make test-f2-tooling` checks its inventory hash.

Alternatives: rewriting history to drop the blobs (rejected: it breaks every clone and
open PR, and the plan forbids it); moving the logs to Git LFS (rejected: a new tool for
files nobody reads); attaching them to a GitHub Release (rejected: release assets are
for distribution, and a commit SHA already preserves them for free); compressing them in
place (rejected: still tracked weight, and diffs become opaque).
