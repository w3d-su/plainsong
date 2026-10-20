# Decision Log entries are one file each under `docs/decisions/`

Every PR appended its row to the last line of the table in `docs/decision-log.md`, so any
two open PRs conflicted there; 28 of the last 40 commits on `main` touched the file. On
2026-10-20, after #181 merged, the four other open macOS PRs (#177, #178, #179, #180) all
conflicted with `main` in that file and nowhere else. A simulated merge of all five was
otherwise clean, built, and passed `make test-packages`. The `main` ruleset does not
require branches to be up to date (`strict_required_status_checks_policy: false`), so a
PR's green `build-and-test` stays valid after another PR merges. The only thing that
forced another CI run (11-25 minutes on recent PRs) was pushing the conflict resolution,
once per PR, one PR at a time. A new file cannot conflict with another PR's new file. The
table stays as the archive and takes no new rows; the format is in its header.

Alternatives: `merge=union` in `.gitattributes` (rejected: GitHub's mergeability check and
web merge ignore merge drivers, and the maintainer squash-merges on GitHub); inserting
rows at random positions in the table (rejected: neighbouring rows still collide, and
date order breaks); a single generated log built from the files (rejected for now: it
needs a script plus a CI check to stay in sync, and agents can read the directory
directly); a merge queue (rejected: it is only available for organization-owned
repositories, and it would still hit the same textual conflict); requiring rebase before
merge (rejected: that is the CI run this removes).
