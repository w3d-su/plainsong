# WYSIWYG fold recompute gates rerun after merging main `d9dc9221` into the promotion branch

- Date: 2026-11-13
- Commit: `78da1a41` (branch `phase3-wysiwyg-promotion-prep`, the merge of `origin/main`
  `d9dc9221`); compared with the pre-merge head `0ea968cf`
- Environment: macOS 27.0 (26A428), Xcode 27.0 (27A5194q), Swift 6.4, Apple M1 Pro,
  16 GB, Debug (`swift test`), on a Mac that runs other work (load never below 3)
- Fixture: `Fixtures/large-1mb.md`; agent.md §12 highlight budget, < 50 ms visible range
- Procedure: `swift build --build-tests` in `Packages/EditorKit`, then three back-to-back
  `swift test --skip-build --filter` runs of
  `MarkdownEditorViewTests/testWYSIWYGVisibleRangeFoldRecomputeStaysUnderHighlightBudget`
  (B10), `WYSIWYGLinkPerformanceGateTests` (L8),
  `WYSIWYGImageThumbnailI8PerformanceGateTests/testI8VisibleRangeRecomputeWithImageFoldingStaysUnderFiftyMilliseconds`
  (I8) and
  `WYSIWYGViewportPerformanceGateTests/testFoldRecomputeOverTheProductionViewportRequestStaysUnderFiftyMilliseconds`.
  1-minute load average 6.5-6.7 during the three runs. The paired and full-suite runs
  below used a second worktree built at `0ea968cf`.
- Result: pass for B10, L8 and I8, alone and in the full suite. The production-viewport
  gate passes alone and **fails in every full-suite run, on the pre-merge build as well**
  (7 of 7, first counted sample 107-143 ms). The merge did not cause it.

## Isolated runs on the merged head

| Gate | Run 1 | Run 2 | Run 3 | Last recorded (2026-10-24) |
|---|---:|---:|---:|---|
| B10 one-line fold recompute (`.inlineFoldReveal`) | 33.254 ms | 27.418 ms | 32.433 ms | 24.821-27.635 ms |
| L8 link folding, max of 3 after warm-up | 16.256 ms | 16.051 ms | 16.313 ms | 15.569-16.016 ms |
| I8 image folding, max of 5 | 16.465 ms | 16.830 ms | 16.666 ms | 16.234-17.307 ms |
| Production viewport, max of 3 after warm-up | 28.119 ms | 27.672 ms | 29.601 ms | 27.197-30.007 ms |

Raw samples (ms): L8 `[15.899, 15.839, 16.256]`, `[16.051, 15.714, 15.831]`,
`[15.960, 16.117, 16.313]`; I8 `[16.187, 16.021, 16.465, 16.377, 16.335]`,
`[16.677, 16.213, 16.411, 16.585, 16.830]`, `[16.372, 16.021, 16.606, 16.348, 16.666]`;
production viewport `[28.119, 27.591, 28.043]`, `[27.672, 27.423, 27.322]`,
`[27.430, 27.653, 29.601]`. The request is still 6,324 UTF-16 units, 6,419 highlighted.

## B10 before and after the merge

B10 takes one sample per run, and two of the three runs above were higher than October's.
Eight interleaved pairs (base run, then head run, each a fresh `swift test` process of B10
and the production-viewport gate; load 4.9-7.3):

| Pair | Base B10 | Head B10 | Base viewport max | Head viewport max |
|---:|---:|---:|---:|---:|
| 1 | 32.001 | 34.348 | 28.326 | 27.996 |
| 2 | 26.494 | 26.325 | 28.023 | 27.805 |
| 3 | 27.258 | 32.184 | 28.827 | 28.394 |
| 4 | 30.064 | 34.005 | 28.491 | 28.805 |
| 5 | 28.380 | 28.114 | 28.012 | 27.816 |
| 6 | 28.051 | 28.774 | 28.257 | 29.800 |
| 7 | 26.879 | 28.532 | 28.040 | 29.309 |
| 8 | 29.079 | 27.531 | 28.114 | 27.720 |
| Median | 28.216 | 28.653 | 28.186 | 28.195 |

B10's paired difference is +1.19 ms at the median (mean +1.45 ms, 5 of 8 pairs positive).
Base alone spans 26.5-32.0 ms today, so this does not separate the two builds, and both
are above the 24.8-27.6 ms recorded in October on the same machine. The viewport gate's
medians are equal. The merge brings #251's line-end hanging-space pass into the
projection; these numbers do not show a cost from it.

## Full EditorKit suite

`swift test --skip-build` (whole package), base and head interleaved, three rounds, plus
one earlier head run. Base is 552 tests and head 560, 9 opt-in skips each. Every run has
exactly one failure, the production-viewport gate.

| Run | 1-min load | Production viewport samples | B10 | L8 max | I8 max |
|---|---:|---|---:|---:|---:|
| Head (first) | 6.8 | `[115.992, 28.528, 27.824]` | 23.980 | 16.872 | 17.063 |
| Base 1 | 5.3 | `[106.560, 28.123, 32.444]` | 25.641 | 17.022 | 17.298 |
| Head 1 | 4.5 | `[108.821, 30.664, 31.956]` | 25.745 | 16.865 | 17.310 |
| Base 2 | 4.0 | `[143.203, 36.980, 34.687]` | 26.137 | 16.968 | 16.751 |
| Head 2 | 4.4 | `[115.262, 30.164, 28.792]` | 26.133 | 16.907 | 19.070 |
| Base 3 | 3.7 | `[109.158, 28.729, 30.330]` | 24.872 | 16.949 | 17.038 |
| Head 3 | 3.2 | `[127.399, 33.806, 28.412]` | 25.966 | 17.027 | 16.887 |

Only the first counted sample is slow, and it is slow after the test's own discarded
warm-up call. B10, L8 and I8 are normal in the same processes.

## What reproduces the full-suite failure

All on the merged head, each a fresh process:

- `--filter WYSIWYG` (195 tests, 8 skipped): fails, `[104.472, 30.528, 29.377]`.
- Every non-WYSIWYG class plus the gate (395 tests): passes, `[29.162, 27.813, 27.956]`.
- Each earlier WYSIWYG class paired alone with the gate: passes every time. The highest
  maxima were 38.163 ms after `WYSIWYGImageThumbnailPresentationTests`, 38.091 ms after
  `WYSIWYGTableMechanismSpikeTests` and 37.938 ms after `WYSIWYGNativePointerGateTests`;
  the rest were 27.9-32.6 ms.

## Reading

- The October record and the audit read this gate's two full-suite failures (80.256 ms at
  load 84-89, 126.578 ms at load 14-47) as contention. That reading does not hold: it
  fails 7 of 7 at load 3-7 while the other three gates in the same process stay at their
  isolated values.
- It is not a regression from this merge: the pre-merge build fails the same way.
- It needs the WYSIWYG test classes run together in one process. No single class causes
  it. The cause is not identified. State left behind by earlier tests (windows, text
  views, caches) is the likely area, and that is an inference, not a measurement.
- Whether a long-running app session can reach the same slow first recompute is not
  known. The gate passing alone shows the steady-state cost of a viewport recompute is
  about 28 ms; it does not rule the other case out.
- CI does not see this: `assertPerformanceBudget` only prints on CI hosts (R15).
