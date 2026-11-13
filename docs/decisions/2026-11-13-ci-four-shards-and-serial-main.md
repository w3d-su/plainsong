# CI runs four hosted shards on pull requests and one shard at a time on main

The 2026-11-02 layout left two delays. The slowest shard set the length of a run, and runs
waited for each other's macOS runners.

Measured over the 19 successful full runs of that layout between 2026-11-10 and 2026-11-12
(job timestamps; "critical path" is the longest chain of job run times with queueing
removed):

| Runs | Count | Wall time, median (range) | Longest macOS queue, median (max) |
|---|---:|---:|---:|
| No macOS job queued 60 s or more | 8 | 10.6 min (9.2–11.3) | 5 s (39 s) |
| A macOS job queued 60 s or more | 11 | 13.5 min (10.9–20.0) | 231 s (649 s) |

The critical path was 9.8 min at the median: `hosted (build)` 3.8 min, then the slowest
shard, `hosted (app)`, 5.8 min. A run used 27.1 macOS minutes.

The queued runs waited for this repository's own runs. CodeQL's Swift analysis stopped
taking a runner on 2026-11-09 (`2026-11-10-codeql-advanced-setup-swift-weekly.md`). Each
merge starts a `push` run on `main` that holds four macOS runners while its shards run, so
the pull request pushed or rebased after a merge finds one runner free. Two merges in a
row, or two pull requests pushed together, do the same.

In the test steps of six of those runs, three classes took 518 s of the 849 s median total:

| Class | Median | Range |
|---|---:|---:|
| `PlainsongUITests/WorkspaceSearchAcceptanceTests` (4 tests) | 196 s | 175–202 |
| `PlainsongTests/EditorFindHostedGateTests` (156 tests) | 163 s | 130–179 |
| `PlainsongUITests/EditorFindAcceptanceTests` (3 tests) | 159 s | 147–164 |

`hosted (app)` ran `EditorFindHostedGateTests` together with most of `PlainsongTests`, and
its test step took 344 s at the median (289–378). The other two took 294 s and 275 s.

## Decisions

- **Four shards.** Each of the three long classes gets its own shard, and the rest of
  `PlainsongTests` is the fourth. `search` runs `WorkspaceSearchAcceptanceTests`; `find`
  runs the other UI tests and `PerformanceTests`; `gate` runs `EditorFindHostedGateTests`,
  `ExportPDFMatrixAppTests` and `ExportPDFWideRunsAppTests`; `app` runs the remaining
  `PlainsongTests` classes. Summing the class medians gives 196, 218, 219 and 216 s of
  tests per shard, plus about 20 s of `xcodebuild` start-up each. That estimate comes from
  the old layout's logs; the first two runs of this one are below. The rule that a named
  class is skipped in its bundle's catch-all shard is unchanged, and so is the bundle
  check in `hosted (build)`.
- **A push to `main` runs its shards one at a time** (`max-parallel: 1`). Nobody waits for
  that run. It still runs every test from the same shard definitions as a pull request, and
  it holds at most two macOS runners (`packages` and `hosted (build)`, then `packages` and
  one shard) instead of four, for about twice as long.
- **`workflow_dispatch` takes `serial_hosted`.** It defaults to off, so a dispatched run is
  as fast as a pull request. Setting it runs the shards as `main` does, which is also the
  only way to exercise that path before a change to it merges.

## Measured on the pull request

Two runs of this layout, against `main`'s run of the parent commit (43274184697, three
shards). Test step times are from the job logs.

| Run | Wall time | Shard test steps | macOS minutes |
|---|---:|---|---:|
| `main` at the parent commit, three shards | 13.0 min, with one job queued 115 s | 268, 269 and 323 s | 27.3 |
| Pull request (43292425748), four at once | 8.7 min, nothing queued | 211, 228, 229 and 237 s | 26.4 |
| `workflow_dispatch` with `serial_hosted` (43293560415) | 23.1 min | 202, 207, 229 and 256 s | 27.1 |

All three executed the same 1,247 tests, each once, with the same 24 skipped. In the
serial run each shard started two to four seconds after the one before it finished, and
`packages` had finished before the first shard started, so the run held two macOS runners
during the build and one after it.

Two runs are a small sample, and runner speed varies between runs. Re-measure after
`main` has run with this layout.

## Cost

A pull request run now holds all five macOS runners while `packages` (7.5 min at the
median) overlaps the four shards, between three and four minutes. Any other macOS job running then
makes one shard wait until a runner is free. Shortening `packages` below the four minutes
`hosted (build)` takes would remove the overlap; that is not part of this change.

## Alternatives considered

- Rebalancing three shards: it costs no runner, but 849 s of tests and three start-ups
  cannot go below about 303 s per shard. That saves about 40 s where four shards save
  about 100 s.
- A separate single job for `main` that runs every bundle in one `xcodebuild` call: it
  saves three job start-ups, about a minute, on a run nobody waits for. It needs a second
  job definition and a `build-and-test` rule for which of the two jobs may be skipped.
- Running only `packages` and `hosted (build)` on `main` to seed caches: the main ruleset
  does not require a branch to be up to date, so a merged commit can be a tree no run has
  tested. The 2026-11-02 decision to test every `main` commit stands.
- Splitting the three long classes by test method: `WorkspaceSearchAcceptanceTests` is
  four tests of 22–65 s. A method list in `ci.yml` has to follow every rename, and with
  four shards it would not shorten the slowest one, which is already within 10% of the
  mean.

Supersedes: the "Three shards, not four" decision in
`2026-11-02-ci-one-hosted-build-and-main-runs.md`. The rest of that file stands.
