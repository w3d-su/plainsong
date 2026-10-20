# Docs-only pull requests skip the test jobs, and `build-and-test` still reports

A docs-only PR ran the full suite: 11-25 minutes on recent runs, with three macOS jobs
competing for GitHub's 5-concurrent macOS job cap. On 2026-10-20, #182 (three Markdown
files) waited 8 minutes for macOS runners before its tests started. CI now runs an
ubuntu `changes` job first. It diffs GitHub's test merge commit against its first parent
(the base branch tip), which is exactly the tree the other jobs would test. It uses
`git diff --name-status --no-renames -z` on a depth-2, blobless, sparse checkout, with no
third-party action. A PR is docs-only when every changed path is under `docs/`, or is a
top-level `*.md` or `LICENSE` file that is not deleted. Exceptions run the full suite:
`docs/perf-log.md` and `docs/evidence/**`, because `make test-packages` reads them
(`Scripts/editor_find_f2_evidence_tests` checks perf-log digests and audits the retained
F2 pack); deleting a top-level file, because `project.yml` lists `agent.md`; an empty diff;
and `workflow_dispatch`. `preview`, `packages` and `hosted` skip when `docs_only` is
`true`. The gate accepts `skipped` only when `changes` succeeded and reported docs-only.
Failures and cancellations still fail it, and so does a test job skipped on any other
path, so the required check keeps its meaning.

Alternatives: workflow-level `paths-ignore` (rejected: the required `build-and-test` check
is never created, so the PR cannot merge); a second workflow with the inverse path filter
and a stub `build-and-test` job (rejected: a mixed PR reports two checks with the required
name, so which one satisfies the ruleset is ambiguous); `dorny/paths-filter` or
`tj-actions/changed-files` (rejected: a new dependency for one shell loop, and
`tj-actions/changed-files` was compromised in March 2025); the REST compare or PR-files API
(rejected: a network call with file-count caps and pagination, where a local diff is
exact); a three-dot `base...head` diff (rejected: it needs enough
history to find the merge base, while the merge commit's first-parent diff needs depth 2
and is the tree under test); treating all of `docs/` as prose (rejected: two paths are
test inputs).

Supersedes: archive row 2026-10-15, "CI runs as parallel jobs behind one `build-and-test`
gate", only in that a skipped job no longer always fails the gate.
