# Why the production-viewport gate failed in the full EditorKit suite: leftover test windows

- Date: 2026-11-13
- Commit: `b3a4e807` (branch `phase3-wysiwyg-promotion-prep`) plus the test-only change in
  this commit
- Environment: macOS 27.0 (26A428), Xcode 27.0 (27A5194q), Swift 6.4, Apple M1 Pro,
  16 GB, Debug (`swift test`), 1-minute load 5-9 unless a row says otherwise
- Fixture: `Fixtures/large-1mb.md`; agent.md §12 highlight budget, < 50 ms visible range
- Follows `docs/perf/2026-11-13-wysiwyg-promotion-gates-after-main-merge.md`, which
  recorded `WYSIWYGViewportPerformanceGateTests` failing 7 of 7 full-suite runs (first
  counted sample 107-143 ms) with the cause not identified.
- Result: the cause is test windows that earlier WYSIWYG fixtures show and never hide.
  With them hidden after each test the gate passes 4 of 4 full-suite runs at
  27.6-32.7 ms. It is a test-suite artifact, not a slow recompute in the editor.

## Cause

Five WYSIWYG fixture factories call `window.makeKeyAndOrderFront(nil)` and return only
the text view. A shown `NSWindow` stays on screen and in `NSApplication.shared.windows`
after the fixture's local reference goes away. Counted with an `XCTestObservation`
observer in a `--filter WYSIWYG` run, by the class that left them:

| Test class | Windows left on screen |
|---|---:|
| `WYSIWYGImageThumbnailPresentationTests` | 20 |
| `WYSIWYGImageThumbnailNativeGateTests` | 16 |
| `WYSIWYGNativePointerGateTests` | 13 |
| `WYSIWYGTableMechanismSpikeTests` | 11 |
| `WYSIWYGEdgeSnappingGateTests` | 6 |
| `WYSIWYGImageThumbnailNativePointerGateTests` | 4 |
| `WYSIWYGLinkNativePointerGateTests` | 4 |
| `WYSIWYGLineEndFoldGeometryTests` | 1 |
| Total when the viewport gate starts | 75 |

The gate adds its own window, so 76 are on screen while it measures.

`EditorPerformanceProbe.measureVisibleRangeHighlightUpdate` times
`await highlightService.highlight(...)`, the attribute apply and `displayIfNeeded()`. The
parse runs off the main actor and the probe resumes on it, so anything else the main
thread does during the `await` is counted. Timing the three parts separately in the
failing sample gave about 105 ms for the `await`, 4 ms for the apply and 0.02 ms for the
display; the other samples spend 24-26 ms in the `await`.

A main-thread stack sampler (a `SIGUSR2` handler calling `backtrace`, one sample about
every 0.66 ms) showed what ran during that `await`: 116 of 153 samples were under
QuartzCore's `CA::timer_callback`, a run-loop timer that commits a `CATransaction` and
waits on `mach_msg` to the render server. It fires once, about 0.8 s after the gate test
starts, which is inside the first counted sample. Roughly 23 ms more went to an
autorelease-pool drain in a main-queue job in the same window.

The timer's cost follows the number of on-screen windows:

| Process | Windows on screen | Time under `CA::timer_callback` |
|---|---:|---:|
| Gate alone | 1 | about 4 ms |
| `--filter WYSIWYG` | 76 | about 77 ms |

This also explains the earlier pairings: the gate's highest maxima when run after a single
class (38.2, 38.1 and 37.9 ms) came after the three classes that leave 20, 11 and 13
windows.

Two checks that moved the failure as this predicts:

- A 1.5 s sleep before the warm-up call lets the timer fire outside the measurement, and
  the slow sample disappears.
- Ordering all 76 windows out at the start of the gate test makes the first sample worse
  (182-392 ms over 3 runs), because the window removal then lands in the measurement.
  The cleanup has to happen when each test ends, not in the gate.

## Change

`TestWindowTeardown.hideAfterCurrentTest(_:)` (EditorKit tests) keeps a fixture's window
until the running test finishes, then orders it out and releases it from an
`XCTestObservation` observer. The five factories call it:
`WYSIWYGEdgeSnappingGateTests`, `WYSIWYGImageThumbnailPresentationTestSupport`,
`WYSIWYGLinkNativePointerGateTests`, `WYSIWYGNativePointerGateTests` and
`WYSIWYGTableMechanismSpikeTestSupport`. No product source changes.

## After the change

Full EditorKit suite, `swift test --skip-build`, 560 tests, 9 opt-in skips, 0 failures in
each of four runs. All values in ms.

| Run | 1-min load | Production viewport samples | B10 | L8 max | I8 max |
|---:|---:|---|---:|---:|---:|
| 1 | 8.2 | `[30.240, 28.088, 27.844]` | 23.757 | 16.708 | 22.521 |
| 2 | 7.2 | `[27.783, 27.599, 27.616]` | 24.695 | 16.746 | 17.305 |
| 3 | 5.7 | `[28.787, 29.739, 28.972]` | 25.651 | 16.681 | 17.032 |
| 4 | 5.1 | `[32.664, 28.459, 28.545]` | 25.703 | 16.984 | 18.625 |

Before the change the same command failed 7 of 7 on this gate. A fifth run that still
carried the diagnostics also passed (viewport maximum 29.198 ms); it showed 2 windows on
screen when the gate started, the gate's own and one left by
`EditorDocumentBindingLifecycleTests`, which this change does not touch. The suite is
about 2 s faster with the windows hidden.

`--filter WYSIWYG` (the subset that reproduced the failure), 21 runs with the change and
the diagnostics still in place:

- Production viewport: under budget in 21 of 21. The maximum was 27.8-31.5 ms in 20 runs
  and 46.890 ms in one.
- I8: 20 of 21 under budget. One run's second sample was 151.584 ms. In 5 of the first 11
  runs the second sample was 23.2-27.2 ms instead of 16-18 ms; in the next 10 runs it was
  16.5-20.2 ms. The 15 runs saved from before the change have every I8 sample at 16-19 ms.
- B10: 28.9-33.8 ms in 20 runs and 221.363 ms in one. B10 takes a single sample with no
  warm-up, and in this subset it runs before any fixture that uses the helper, so the
  change cannot have caused that sample.

Closing the windows instead of ordering them out, and hiding them while keeping them
alive, were each run 5 times. Both keep the viewport gate under budget (27.7-33.7 ms and
28.1-46.2 ms). Neither removed the occasional 23 ms I8 sample, so the simplest form stayed.

## Not established

- What arms the timer. `backtrace_symbols` and `atos` name the function under
  `CA::timer_callback` only by its nearest exported symbol, so it is described here by
  what it does.
- The I8 samples above. Sampling the main thread during a post-change I8 run showed a
  display-link callback committing a transaction (9-11 ms) and an AppKit alpha animation,
  with no test window on screen. Whether hiding the windows makes these more likely to
  land in I8, and what the one 151.584 ms sample was, is not known. It did not recur in
  the 10 later subset runs or in the 5 full-suite runs.
- Other packages and the hosted tests were not checked for leftover windows.

## Reading

- The October record and the audit read this gate's failures as contention, and the
  earlier record today left the cause open. It is neither load nor the editor: the gate
  measured a Core Animation commit for 76 on-screen windows that happened to fall inside
  its first sample.
- The cost depends on how many windows the process has on screen, not on how long it has
  run. The steady-state viewport recompute is about 28 ms with or without the leftover
  windows. Only 1 and 76 windows were measured.
- These gates count any main-thread work that lands in the `await`. One slow sample among
  normal ones in the same process is a reason to look at what else the main thread did
  before reading it as a regression.
- CI does not see any of this: `assertPerformanceBudget` only prints on CI hosts (R15).
