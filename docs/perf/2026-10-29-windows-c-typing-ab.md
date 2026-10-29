# Windows PR C adds no keystroke publish and leaves typing latency within noise

- Date: 2026-10-29
- Commit: `phase3-windows-pr-c` (the commit that adds this file) against `main` at `88e3a773`
- Environment: macOS 27.0, Xcode 27.0 (27A5194q), Apple M1 Pro, Debug. The 1-minute load
  average was 6.36–7.08 across the runs, recorded per run below.
- Fixture: `Fixtures/large-1mb.md`. Budget: `agent.md` §12 typing < 16 ms.
- Procedure: as in `docs/perf/2026-10-27-windows-b1-typing-ab.md`.
  - `build-for-testing` each tree into its own DerivedData.
  - Run six interleaved pairs of `xcodebuild test-without-building -xctestrun <tree>.xctestrun
    -destination 'platform=macOS,arch=arm64'` with
    `-only-testing:PerformanceTests/PerformanceBudgetTests/testTypingLatencyStaysUnderFrameBudget`
    and
    `-only-testing:PerformanceTests/AppBackedEditorPerformanceTests/testHostedPublicEditorCurrentRevisionInputAndMarkedTextStayWithinFrameBudget`.
  - Odd pairs run `main` first and even pairs run C first.
- Result: pass. All 24 test runs passed and every sample is under 16 ms. The paired
  differences change sign, and no metric moved beyond its run-to-run spread.

Why it was measured: C routes a text view's command through its own window and adds
`menuEnablementDidChange` so Save re-reads fences without publishing them. Neither path
publishes a body edit. `WindowStatePartitionPublishAppTests/testBodyEditsPublishOnlyTheSessionsOwnChanges`
still counts one `AppState.objectWillChange` per 20 body edits, matching the session's own
`isDirty` flip.

## App-backed hosted typing (goes through `AppState`)

Each value is the single timed native insertion plus public-view update that the test prints,
in ms. The load column gives the 1-minute load at the start of the pair's first and second run.

| Pair (order) | Load | `main` ordinary | C ordinary | `main` pair | C pair | `main` marked max | C marked max |
|---|---|---:|---:|---:|---:|---:|---:|
| 1 (main, C) | 6.42 / 6.86 | 7.062 | 9.342 | 6.098 | 6.064 | 9.159 | 6.321 |
| 2 (C, main) | 6.39 / 6.39 | 7.742 | 7.794 | 4.813 | 6.390 | 6.697 | 4.976 |
| 3 (main, C) | 6.36 / 6.36 | 9.476 | 7.727 | 5.755 | 5.797 | 6.749 | 5.284 |
| 4 (C, main) | 6.89 / 6.74 | 7.312 | 9.733 | 5.063 | 6.227 | 5.120 | 5.168 |
| 5 (main, C) | 6.74 / 7.08 | 9.556 | 7.164 | 5.905 | 4.702 | 5.136 | 6.512 |
| 6 (C, main) | 7.08 / 6.83 | 7.518 | 9.386 | 5.306 | 5.423 | 4.999 | 5.122 |
| Median | | 7.630 | 8.568 | 5.531 | 5.930 | 5.917 | 5.226 |
| Paired C − `main`, mean (range) | | | +0.413 (−2.392 to +2.421) | | +0.277 (−1.203 to +1.577) | | −0.746 (−2.838 to +1.376) |

## §12 typing test (EditorKit only)

The value is the per-scenario maximum the test prints, in ms; each list holds the six runs.

| Scenario | `main` | C |
|---|---|---|
| markdown plain (200) | 0.002 0.002 0.005 0.005 0.002 0.003 | 0.003 0.003 0.003 0.002 0.002 0.002 |
| markdown newline (200) | 0.080 0.046 0.043 0.043 0.044 0.041 | 0.086 0.043 0.047 0.043 0.040 0.038 |
| markdown pair (50) | 0.167 0.158 0.161 0.164 0.162 0.191 | 0.166 0.153 0.288 0.153 0.167 0.158 |
| mdx plain (200) | 0.001 0.001 0.001 0.001 0.001 0.001 | 0.001 0.001 0.001 0.012 0.001 0.001 |
| mdx jsx trigger (50) | 0.136 0.138 0.125 0.121 0.122 0.126 | 0.121 0.179 0.165 0.119 0.175 0.123 |

The app-backed test takes one sample per run, so six pairs bound a regression only to about
the ±2.4 ms spread seen here. C's one EditorKit change returns from a command when its window
is not key; the key window's own keystroke path is unchanged. These are Debug numbers under
the normal 6–8 load, not a Release or idle-machine measurement. W12 (typing with four windows)
stays a separate gate.
