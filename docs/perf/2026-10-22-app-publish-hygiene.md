# Completion refresh per typing pause: cached workspace base vs full rebuild

- Date: 2026-10-22
- Commit: branch `phase3-app-publish-hygiene` against `origin/main` `6bf644e`
- Environment: macOS 27.0 (26A428), Xcode 27.0 (27A5194q), Apple M1 Pro 16 GB,
  `swift test -c release -Xswiftc -enable-testing` (WorkspaceKit), load average 36-67
  during the run (other agents building)
- Fixture: generated workspace, 60 sibling posts (6-key frontmatter + ~29 KB body each) and
  a 200 KB current file with 50 `##` headings; no agent.md §12 budget applies
- Procedure: a temporary, uncommitted XCTest in a `git archive` copy of each revision's
  `Packages/` timed the provider (median of 9 calls per run). Main and branch runs were
  interleaved, 12 pairs, with the 1-minute load average recorded per pair.
- Result: per typing pause, 66.6 ms (main, full rebuild) → 4.2 ms (branch, cached base +
  anchors), median paired ratio 0.076 (−92%). The first refresh per installed capture still
  reads the siblings: 73.1 ms vs 66.6 ms, median paired ratio 1.02 (no change within noise).

| pair | load | main full (ms) | branch first refresh (ms) | branch per pause (ms) |
|---:|---:|---:|---:|---:|
| 1 | 36.4 | 35.6 | 32.5 | 3.6 |
| 2 | 38.1 | 38.1 | 66.8 | 4.1 |
| 3 | 36.4 | 67.2 | 136.4 | 5.2 |
| 4 | 41.3 | 83.6 | 77.7 | 13.1 |
| 5 | 47.4 | 98.6 | 70.7 | 4.0 |
| 6 | 53.8 | 61.5 | 89.0 | 4.7 |
| 7 | 62.7 | 54.6 | 60.6 | 3.4 |
| 8 | 65.4 | 42.9 | 29.2 | 3.4 |
| 9 | 66.2 | 66.1 | 34.0 | 3.1 |
| 10 | 63.0 | 70.8 | 108.9 | 5.4 |
| 11 | 62.0 | 77.6 | 104.9 | 5.2 |
| 12 | 67.4 | 115.0 | 75.5 | 4.3 |

The bounded prefix read does not make the first refresh cheaper with ~29 KB siblings: the
cost is the per-file anchored open and namespace validation, not the bytes. It bounds the
read for large siblings. The saving is that the read happens once per capture instead of
once per pause.

Publishes are counted, not timed: on `main` each typing pause assigned
`completionWorkspace` (one whole-window `AppState` publish) and, with a Find query active,
each edit's counter refresh sent `objectWillChange` even when the counter text was
unchanged. On the branch a body edit publishes neither
(`AppPublishHygieneTests.testBodyEditRepublishesCompletionWorkspaceOnlyWhenItsValueChanges`,
`testIdenticalFindChromePublishesNothing`). The inspector's per-change frontmatter work on
`Fixtures/large-1mb.md` (in-process, 12 interleaved samples, release): `Frontmatter.parse`
0.20-0.36 ms after warm-up vs 0.001 ms for the memo's prefix check; the larger saving is
that editor typing no longer re-renders the inspector per keystroke (150 ms debounce).
