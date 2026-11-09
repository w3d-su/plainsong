# CI builds hosted tests once, lints on Ubuntu, and runs every main commit

Over the last 50 CI runs, queueing and setup were small: about 0.1 min of queue and under
1 min of setup per job. The time was inside the test steps. Each hosted shard spent about
50 s cloning Xcode packages and 3 min compiling every bundle, `packages` spent about 1 min
on lint, and a bit-at-a-time CRC in a PNG fixture spent about 2 min. Every new PR also
started without caches: there was no push build on `main`, so `main` held none, and a PR
cannot read another PR's cache. Each PR saved its own 815 MB copy, which held the repository
above GitHub's 10 GB limit.

## Decisions

- **One hosted build.** `hosted (build)` runs `build-for-testing`, then uploads a 32 MB
  tar with `Build/Products`. Three shards download it and run `xcodebuild
  test-without-building -xctestrun`. tar keeps the symlinks and signatures an artifact zip
  would lose. The artifact name has no attempt number, so re-running one failed shard
  reuses the products.
- **Three shards, not four.** CodeQL's default setup runs `Analyze (swift)` on
  `macos-latest` for about 12 minutes per push, and that shares the 5-runner macOS cap. With
  `packages`, CodeQL and four shards, one shard queued for 193 s. A shard that names a class
  also skips it in the bundle's catch-all shard, so a new or renamed class still runs. A
  new test bundle is not covered that way: `hosted (build)` fails unless the bundles in the
  built `.xctestrun` are exactly the ones the shards name (`Scripts/check-xctestrun-bundles.py`).
- **Style lint on Ubuntu.** SwiftFormat and SwiftLint are SHA-256-verified release binaries.
  SwiftFormat's content-keyed cache is restored between runs, because it takes about 110 s
  cold on Ubuntu. The static SwiftLint binary has no SourceKit, so CI skips
  `statement_position`, the only affected rule. It only warns, so it never changed whether
  lint passed, and local `make lint` still reports it. The lint step fails if SwiftLint
  reports skipping any other rule, so an upgrade cannot silently drop more.
- **Every main commit runs.** A `push` trigger on `main` replaces the 2026-07-02
  pull-request-only rule, which existed because of private-repository macOS pricing; the
  repository is public now and macOS minutes are free. `main` also seeds the caches every PR
  restores. Each non-PR run has its own concurrency group: a shared group keeps only the
  newest waiting run, which would silently drop commits even with `cancel-in-progress` off.
- **`push` has a path filter; `pull_request` does not.** A filtered PR run never reports
  the required `build-and-test` check and blocks the merge. PRs keep the `changes` job from
  the 2026-10-20 decision. The push filter re-includes the same two docs paths that are test
  inputs.
- **A real CRC in the PNG fixture.** `ExportRasterFixture` used a bit-at-a-time CRC over
  10 MiB in a debug build, and 11 tests spent 105 s on it locally. zlib computes the same
  CRC-32, and those tests now take 0.5 s.

## Measured (2026-11-10)

From the job timestamps of the 150 CI runs between 2026-10-25 and 2026-11-06. "Critical
path" is the longest chain of job run times with queueing removed; "macOS minutes" is the
sum of the macOS jobs' run times. All figures are medians of successful full runs.

| Layout | Runs | Critical path | macOS minutes |
|---|---:|---:|---:|
| Before (`packages` + two hosted jobs), whole window | 86 | 11.8 min | 32.3 |
| Before, 2026-11-01 onward | 25 | 12.7 min | 34.1 |
| After (this decision), before `main` seeds any cache | 4 | 10.2 min | 27.1 |

The four "after" runs ranged 9.5–10.7 min and 26.6–27.7 macOS minutes. Four runs is a
small sample; re-measure after `main` has run with this layout.

Queueing, not execution, sets the worst case, and this decision does not remove it. Median
wall time of a before-layout run by how many test runs started within ten minutes of it:
alone 13.1 min (34 runs), two 14.9, three 19.7, four 22.5, five or more 60.4 (7 runs, max
63.4). A run here holds four macOS runners where the old layout held three, so two
simultaneous runs still queue; fewer macOS minutes per run is what shortens that queue.

## Stays on macOS

`make check-preview-layering` resolves `project.yml` through xcodegen, which has no Linux
binary. `make test-f2-tooling` hard-codes `/private/tmp`.

## Alternatives considered

- Removing Swift from CodeQL's default setup, or moving it to a schedule: this would free a
  macOS runner and allow a fourth shard, but it is a security-scanning decision for the
  maintainer, so CI works around it.
- Splitting `packages` into two jobs: with CodeQL's runner taken, this leaves a shard
  waiting until a `packages` job finishes, which is slower than one job.
- Caching DerivedData: checkout resets file times, and llbuild compares inodes, so it needs
  build-system overrides, and a stale hit would be a false green.
- The dynamic SwiftLint binary, which has SourceKit: it needs `libxml2.so.2`, which the
  runner image does not ship, and one warning-only rule does not justify an `apt` step.
