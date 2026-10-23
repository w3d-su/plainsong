# Fence-context scans at the end of a 1 MiB document

- Date: 2026-10-22
- Commit: base `6bf644e` (`origin/main`) vs `phase3-editor-fence-scan` (one shared
  `MarkdownFenceScanner`)
- Environment: macOS 27.0 (26A428), Xcode 27.0 (27A5194q), Swift 6.4, Apple M1 Pro,
  release (`swift build -c release`) executables linking each side's `SyntaxKit` and
  `MarkdownCore`
- Fixture: `Fixtures/large-1mb.md` (1,048,962 UTF-16 units); agent.md §12 budgets
  (highlight < 50 ms visible range, typing < 16 ms)
- Procedure: one executable per side, 12 interleaved pairs, order alternating
  base-first / head-first; each run reports the median of 30 timed calls after 3 warm-up
  calls. 1-minute load average 52.1-78.5 during the run.
- Result: every path is far under budget after the change; head was faster in every
  pair for the three fence paths.

| Path | Base median | Head median | Paired ratio median | Head faster |
|---|---:|---:|---:|---:|
| `visibleHighlightRange`, viewport inside the last fenced block | 16.008 ms | 0.972 ms | 0.060 (-94.0%) | 12/12 |
| `visibleHighlightRange`, viewport on the last section's prose | 15.927 ms | 0.966 ms | 0.060 (-94.0%) | 12/12 |
| Enter after ```` ``` ```` at the end, `NSTextStorage.string` | 27.425 ms | 1.191 ms | 0.042 (-95.8%) | 12/12 |
| MDX `<Ca` completion at the end | 30.585 ms | 17.290 ms | 0.561 (-43.9%) | 11/12 |

Base ranges: 15.6-59.7, 15.5-49.5, 26.7-97.4 and 30.3-60.2 ms (the high values are the
first two pairs, when load was rising). Head ranges: 0.95-1.13, 0.95-1.01, 1.13-1.28 and
16.8-64.4 ms.

The highlight rows are the whole fence/frontmatter context expansion that runs once per
source highlight, off the main actor. Enter runs on the main thread, so the base cost
was a 27 ms keystroke stall at the end of the fixture. Completion still takes about
17 ms after the change: a one-off probe on the head build measured
`MDXImportParser.componentNames(in:)` at 16.4 ms and the fence check alone at 0.7 ms,
so the rest is the import scan, which this change does not touch.

The hosted gate `PerformanceBudgetTests.testVisibleRangeHighlightUpdateAtTheEndOfLargeMarkdownStaysUnderBudget`
(Debug, through `MarkdownHighlightService`) covers the same two viewports against the
50 ms highlight budget.
