# `make test-packages` builds every package, then runs three test lanes; CI runs three at once

CI's `packages` job outlasted `hosted (build)`, so it still held a macOS runner when the
hosted shards started. Over the 21 successful runs with a restored SwiftPM cache between
2026-11-10 and 2026-11-14 (job and step timestamps):

| | Median | Range |
|---|---:|---:|
| `packages` job | 434 s | 354–546 |
| its `Test packages` step | 379 s | 314–468 |
| the rest of that job (checkout, xcodegen, cache restore, layering check) | 54 s | 40–78 |
| `hosted (build)` job | 240 s | 154–308 |

GitHub gives the account five macOS runners. With four shards (pull request #263) a run
wants all five for as long as `packages` overlaps the shards, about three minutes.

The step ran one thing at a time on a three-core runner. In run 43279996338 (321 s) it
spent 30 s in `xcodegen`, the Python tooling tests and the script self-tests, 55 s in
MarkdownCore, 85 s in EditorKit, 90 s in PreviewKit, 28 s in WorkspaceKit, 18 s in
SyntaxKit and WorkspaceCore, and 14 s in the two sandbox probes. About 200 s of that was tests running, not compiling: PreviewKit's 81 s is
mostly waiting for WebKit, and one MarkdownCore test uses one core for 27 s.

## Decisions

- **Build first, then test, then sandbox probes.** `make test-packages` runs
  `swift build --build-tests` for the six packages and starts the test lanes only when
  every build has ended. `package-test-%` runs `swift test --skip-build` so SwiftPM
  executes the built test products instead of reusing `swift build`'s llbuild plan (which
  caused `swift-package` to segfault with `EXC_BAD_ACCESS` on two of five CI runs when
  `swift test` replanned after `swift build --build-tests`). Once all three lanes finish,
  `make test-packages-sandbox` runs serially. Because the sandbox probes compile with
  `swift build`, `swift test`, and `swiftc`, running them after the lanes means no timed
  package test is ever timed beside a compiler: PreviewKit's hosted tests allow 8 s for
  the page and 2 s for a JavaScript reply, 70 of the 76 waits in EditorKit's tests are
  2 s, and the tooling tests give subprocesses 2 s.
- **Three test lanes.** `preview` is PreviewKit. `editor` is EditorKit, then the Python
  tooling tests and the script self-tests. `core` is MarkdownCore, WorkspaceKit, SyntaxKit
  and WorkspaceCore. By the test times above that is about 85, 80 and 60 s (plus ~14 s for
  the serial sandbox probes afterward). The Makefile stops with an error when a package in
  `PACKAGES` or `PORTABLE_PACKAGES` is in no lane or in two, or when `test-packages-tooling`
  is missing or duplicated.
- **`TEST_PACKAGES_JOBS` sets how many builds, then lanes, run at once. CI passes 3; the
  default is 1.** With 1 everything runs in order with live output and stops at the
  first failure, as before. The default stays 1 because the packages' wall-clock budgets
  (`assertPerformanceBudget`, `assertTextSearchDurationUnderLocally`) only print on CI
  but fail a test anywhere else, and `make test` should not start failing because lanes
  compete for cores. `make test-packages TEST_PACKAGES_JOBS=3` works locally.
- **One log per lane.** `Scripts/run-test-lanes.py` runs each lane as `make <target>` in
  its own session and writes its output to its own file. A lane's log is printed whole
  when the lane ends. A failed lane does not stop the others; its log is printed last,
  followed by one line per lane, and the step fails. GitHub folds a passed lane's log
  into a group and gets an error annotation for a failed one. On SIGINT, SIGTERM, or
  SIGHUP, the runner sends SIGINT and SIGTERM to every process group in each running
  lane's session (reaching `xctest` children that SwiftPM's `Process` put in their own
  process group), escalates to SIGKILL after the grace period, and prints the logs of
  already-failed and interrupted running lanes before exiting. `Scripts/test-run-test-lanes.py`
  covers this and runs in the `editor` lane.

The same things run as before: the tooling tests, the script self-tests, `swift test` in
six packages and the two sandbox probes. `make test-portable-core` is unchanged.

## What the lanes share

- **`.build`.** Each package has its own; a path dependency is compiled into the
  `.build` of the package that depends on it. The sandbox probes use `WorkspaceKit`'s
  `.build`, and run serially after all test lanes finish.
- **SwiftPM's cache** (`~/Library/Caches/org.swift.swiftpm`). The six packages were
  resolved at the same time into one empty `--cache-path`, twice, and every resolve
  succeeded. CI normally restores the cache and fetches nothing.
- **Process-wide state in tests.** The package tests use no `UserDefaults.standard` and
  no general pasteboard (suite names and uniquely named pasteboards instead), and their
  temporary directories have unique names. Only PreviewKit uses WebKit. Only
  WorkspaceKit watches file-system events, on its own temporary roots.
- **`/private/tmp`.** The tooling tests create uniquely named directories there.
  Nothing else in the job uses those names.
- **The generated project.** `generate` runs once, before the first build. Only the
  sandbox probes read `App/Plainsong.entitlements`, and nothing regenerates it while
  lanes run.

A search of the package tests found six that assert on elapsed time with no CI
exemption:
`CompletionEngineTests` (fastest of five samples under 16 ms),
`EditorTextElementCacheTrimmerTests` and `EditorLineNumberGutterTypingTests` (ratios of two
timings from the same process), `SVGAssetDeliveryTests` (1 s), `PreviewHostedDeadlineTests`
(2 s for a 10 ms timeout) and `WorkspaceEventWatcherTests` (1 s for a 200 ms maximum
delay). They now run while two other test lanes run, but never while anything compiles.

## Measured

Local, an 8-core Mac at load 7–30, builds current: 198 s with one job; 88, 91 and 124 s
with three, every test passing with the local budgets enforced.

CI: see the table below, filled in from the pull request's runs.

| `packages` on CI | Runs | Job, median (range) | `Test packages` step, median (range) |
|---|---:|---:|---:|
| Before, restored cache | 21 | 434 s (354–546) | 379 s (314–468) |
| After | pending | pending | pending |

## Limits

- Runner speed varies about twofold between runs, so compare medians.
- A handful of green runs cannot show a failure that happens once in fifty runs. If a
  package test starts failing only on CI, set `TEST_PACKAGES_JOBS=1` in `ci.yml` first:
  that is the previous behavior and a one-line change.
- A cache miss (a changed `Package.swift` or `Package.resolved` with no fallback cache)
  builds three packages from nothing at once on a 7 GB runner. That was not measured.

## Alternatives considered

- Lanes that each build and test their own packages, with no separate build phase: one
  fewer `swift` start per package, perhaps 30 s faster. PreviewKit's tests would start
  while EditorKit was still compiling on the same three cores. Not measured; rejected for
  the timing limits listed above.
- A second `packages` job: it takes another macOS runner, which is the problem.
- `make -j`: Apple's make is 3.81 and has no `--output-sync`, so logs would interleave.
- A shell runner: macOS bash is 3.2, with no `wait -n`, and putting lanes in their own
  process groups needs `set -m`, which also moves the terminal's foreground group.
  `/usr/bin/python3` is already required by the tooling tests.
- Three jobs by default off CI: the wall-clock budgets fail tests there.
- `swift test --parallel` inside a package: it splits a package's tests over several
  processes, and most EditorKit and PreviewKit tests drive AppKit or WebKit on the main
  actor with waits tuned for one process. Not tried.
- Shrinking the 1.16 GB cache (19–52 s to restore), for example without the index
  store: the build flags would have to match in the sandbox probe scripts too. Left for
  a separate change.
