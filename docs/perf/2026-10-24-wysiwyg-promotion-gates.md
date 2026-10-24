# WYSIWYG fold recompute gates rerun for the stable promotion, plus the real viewport

- Date: 2026-10-24
- Commit: `ca6b6a7` (branch `phase3-wysiwyg-promotion-prep`, `origin/main` `1428bf1` plus
  test-only commits), with comment-only EditorKit edits in the working tree
- Environment: macOS 27.0 (26A428), Xcode 27.0 (27A5194q), Swift 6.4, Apple M1 Pro,
  16 GB, Debug (`swift test`), on a Mac shared with other agents' builds
- Fixture: `Fixtures/large-1mb.md`; agent.md §12 highlight budget, < 50 ms visible range
- Procedure: `swift build --build-tests`, then three back-to-back
  `swift test --skip-build --filter` runs of
  `MarkdownEditorViewTests/testWYSIWYGVisibleRangeFoldRecomputeStaysUnderHighlightBudget`
  (B10), `WYSIWYGLinkPerformanceGateTests` (L8),
  `WYSIWYGImageThumbnailI8PerformanceGateTests/testI8VisibleRangeRecomputeWithImageFoldingStaysUnderFiftyMilliseconds`
  (I8) and the new
  `WYSIWYGViewportPerformanceGateTests/testFoldRecomputeOverTheProductionViewportRequestStaysUnderFiftyMilliseconds`.
  1-minute load average 12.2-13.7 during the three runs.
- Result: pass. Every sample of every gate is under 50 ms.

| Gate | Run 1 | Run 2 | Run 3 | Last recorded |
|---|---:|---:|---:|---|
| B10 one-line fold recompute (`.inlineFoldReveal`) | 27.635 ms | 24.821 ms | 26.001 ms | 26.964 ms, 2026-06-26 |
| L8 link folding, max of 3 after warm-up | 15.569 ms | 16.016 ms | 15.930 ms | 16.968 ms, 2026-07-06 |
| I8 image folding, max of 5 | 16.234 ms | 16.690 ms | 17.307 ms | 15.234 ms, 2026-07-11 |
| Production viewport, max of 3 after warm-up | 27.379 ms | 30.007 ms | 27.197 ms | new |

Raw samples (ms): L8 `[15.294, 14.973, 15.569]`, `[15.546, 15.707, 16.016]`,
`[15.846, 15.930, 15.895]`; I8 `[15.855, 15.824, 16.234, 16.145, 15.786]`,
`[16.633, 16.690, 16.535, 16.263, 16.474]`, `[17.307, 16.427, 16.661, 16.642, 16.215]`;
production viewport `[27.379, 26.897, 27.031]`, `[27.376, 30.007, 27.451]`,
`[27.197, 27.048, 27.052]`.

B10, L8 and I8 time one paragraph or less. The production-viewport gate times the range
`MarkdownEditorView.highlightRequestRange` asks for after a 1200 x 800 editor scrolls to
the edit in the second half of the fixture: 6,324 UTF-16 units requested, 6,419 highlighted
after context expansion, with `.inlineFoldRevealWithLinkFolding`. That range already
includes STTextView 2.4's viewport extension above the visible text and the 1-4 Ki padding.

An earlier full `swift test` of EditorKit on the same tree failed L8 once at 159.651 ms
(samples `[159.651, 24.449, 30.270]`) at a 1-minute load average of 85-106 while three
other sessions built. The isolated reruns above passed at load 12-14, so that failure is
counted as contention (R15), not a regression.

A final full `swift test` on `a56f412` at load 84-89 shows the same pattern for the new gate:
production viewport `[80.256, 41.429, 35.760]` (fail), L8 `[43.005, 21.569, 18.257]`, I8
max 18.729 ms, B10 35.930 ms. Like L8, the new gate is hard locally and informational on CI;
rerun it alone on a quieter machine before reading a failure as a regression.
