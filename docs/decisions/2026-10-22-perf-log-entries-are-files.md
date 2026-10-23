# Performance measurements are one file each under `docs/perf/`

Performance PRs appended a dated section to the end of `docs/perf-log.md`, so any two
open performance PRs conflicted there. Of the last 40 commits on `main` at `d674aaa`,
13 touch that file. #189 and #193 both append at the same end, and #189 already
conflicted with #154 the same way. Resolving the conflict pushes a new commit and
forces another 11-25 minute CI run. The `main` ruleset does not require branches to
be up to date (`strict_required_status_checks_policy: false`), so without the textual
conflict a green `build-and-test` stays valid. A new file cannot conflict with another
PR's new file. The existing sections stay in `docs/perf-log.md` as the archive; only
its header changes, so an open PR that still appends does not gain a conflict from
this change.

`Scripts/editor_find_f2_evidence_tests` reads the archive for the current F2
trust-root rows: each tooling-digest row must appear once, and the inventory and
verifier digests must each appear three times. Those rows stay in the archive, so
the reader is unchanged and `make test-f2-tooling` still passes. `docs/perf-log.md`
remains a CI test input for that reason (the 2026-10-20 docs-only fast path), so
this change itself runs the full suite. A later measurement file under `docs/perf/`
is ordinary documentation and takes the fast path. Code comments and gate citations
of archive sections stay valid because the sections do not move.
`docs/window-state-gates.md` cited two archive lines by number; those numbers move
with the header and are updated in the same commit.

Alternatives: `merge=union` in `.gitattributes` (rejected: GitHub's mergeability check
and web merge ignore merge drivers, and the maintainer squash-merges on GitHub);
inserting sections at random positions (rejected: neighbouring sections still collide,
and date order breaks); a single generated log built from the files (rejected for
now: it needs a script plus a CI check to stay in sync, and agents can read the
directory directly); a merge queue (rejected: it is only available for
organization-owned repositories, and it would still hit the same textual conflict);
requiring rebase before merge (rejected: that is the CI run this removes); moving
the trust-root rows into `docs/perf/` and teaching the F2 test the new path
(rejected: the rows are retained evidence the test already finds in the archive, and
editing `Scripts/` is a separate change from stopping the append conflict).
