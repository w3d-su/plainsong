# Windows PR B1 adds no keystroke publish and leaves typing latency within noise

- Date: 2026-10-27
- Commit: `phase3-window-state-b1` (the commit that adds this file) against `main` at
  `282a798`. The measured B1 build differs from that commit only by a one-line doc comment
  in `App/AppState.swift`.
- Environment: macOS 27.0, Xcode 27.0 (27A5194q), Apple M1 Pro, Debug. The dev Mac is never
  idle: the 1-minute load average was 17.6–22.9 across the runs (recorded per run below).
- Fixture: `Fixtures/large-1mb.md`. `agent.md` §12 typing budget < 16 ms (W1 bullet 5 in
  `docs/window-state-gates.md`).
- Procedure: `build-for-testing` each tree into its own DerivedData. Then six interleaved
  pairs of `xcodebuild test-without-building -xctestrun <tree>.xctestrun -destination
  'platform=macOS,arch=arm64'` with
  `-only-testing:PerformanceTests/PerformanceBudgetTests/testTypingLatencyStaysUnderFrameBudget`
  and
  `-only-testing:PerformanceTests/AppBackedEditorPerformanceTests/testHostedPublicEditorCurrentRevisionInputAndMarkedTextStayWithinFrameBudget`.
  Odd pairs ran `main` first; even pairs ran B1 first. The publish probe was a temporary
  hosted test, run in each tree and not committed. It sent 200 single-character body edits
  through `AppState.replaceDocumentText` and counted `AppState.objectWillChange` and
  `DocumentSession.objectWillChange` sends.
- Result: pass. All 24 test runs passed. Every sample is under 16 ms. The paired
  differences change sign, and no metric moved beyond its run-to-run spread. The publish
  counts are identical.

## Publishes per keystroke

| Tree | Body edits | `AppState.objectWillChange` | `DocumentSession.objectWillChange` |
|---|---:|---:|---:|
| `main` `282a798` | 200 | 1 | 1 |
| B1 | 200 | 1 | 1 |

The one send is the session's own `isDirty` flip on the first edit. On both trees, `AppState`
forwards it, and no edit after that publishes anything. On B1 the committed test
`WindowStatePartitionPublishAppTests/testBodyEditsPublishOnlyTheSessionsOwnChanges` keeps this
property.

## App-backed hosted typing (goes through `AppState`)

Each value is the one timed native insertion plus public-view update that the test prints,
in ms.

| Pair (order) | Load | `main` ordinary | B1 ordinary | `main` pair | B1 pair | `main` marked max | B1 marked max |
|---|---|---:|---:|---:|---:|---:|---:|
| 1 (main, B1) | 22.9 / 22.1 | 8.870 | 7.651 | 7.986 | 9.105 | 10.342 | 7.064 |
| 2 (B1, main) | 21.0 / 21.0 | 7.899 | 7.199 | 8.518 | 7.584 | 7.681 | 7.043 |
| 3 (main, B1) | 22.7 / 22.0 | 9.615 | 7.600 | 7.432 | 8.018 | 7.771 | 6.692 |
| 4 (B1, main) | 22.0 / 20.9 | 8.824 | 9.697 | 6.818 | 8.157 | 6.990 | 7.775 |
| 5 (main, B1) | 19.8 / 19.8 | 7.709 | 9.554 | 8.433 | 7.742 | 6.668 | 6.848 |
| 6 (B1, main) | 18.5 / 18.5 | 8.448 | 7.553 | 7.318 | 7.833 | 7.819 | 5.779 |
| Median | | 8.636 | 7.625 | 7.709 | 7.926 | 7.726 | 6.946 |
| Paired B1 − `main`, mean (range) | | | −0.352 (−2.015 to +1.845) | | +0.322 (−0.934 to +1.339) | | −1.012 (−3.278 to +0.785) |

The load column gives the 1-minute load at the start of the pair's first and second run.

## §12 typing test (EditorKit only; a control, since B1 changes no EditorKit code)

The value is the per-scenario maximum the test prints, in ms; each list holds the six runs.

| Scenario | `main` | B1 |
|---|---|---|
| markdown plain (200) | 0.002 0.002 0.003 0.002 0.002 0.003 | 0.004 0.003 0.003 0.003 0.003 0.003 |
| markdown newline (200) | 0.086 0.044 0.040 0.046 0.044 0.057 | 0.091 0.043 0.041 0.048 0.047 0.046 |
| markdown pair (50) | 0.171 0.382 0.256 0.292 0.170 0.289 | 0.278 0.160 0.159 0.166 0.162 0.162 |
| mdx plain (200) | 0.002 0.003 0.001 0.001 0.002 0.002 | 0.002 0.004 0.003 0.001 0.002 0.002 |
| mdx jsx trigger (50) | 0.224 0.252 0.197 0.138 0.222 0.145 | 0.145 0.165 0.217 0.205 0.225 0.263 |

The app-backed test takes one sample per run, so six pairs bound a regression only to about
the ±2 ms spread seen here. That is enough to close W1 bullet 5: B1 adds no publish and no
work per keystroke, it changes only where `AppState` stores its properties, and nothing
moved beyond noise. These are Debug numbers under load, not a Release or idle-machine
measurement. W12 (typing with four windows) stays a separate gate.
