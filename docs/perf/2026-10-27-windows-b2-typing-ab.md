# Windows PR B2's registry membership check on the editor-publication path leaves typing within noise

- Date: 2026-10-27
- Commit: `phase3-window-state-b2` (the commit that adds this file) against `main` at `a210f85`
- Environment: macOS 27.0, Xcode 27.0 (27A5194q), Apple M1 Pro, Debug. The 1-minute load
  average was 9.8–12.0 across the runs, recorded per run below.
- Fixture: `Fixtures/large-1mb.md`. Budget: `agent.md` §12 typing < 16 ms.
- Procedure: as in `docs/perf/2026-10-27-windows-b1-typing-ab.md`.
  - `build-for-testing` each tree into its own DerivedData.
  - Run six interleaved pairs of `xcodebuild test-without-building -xctestrun <tree>.xctestrun
    -destination 'platform=macOS,arch=arm64'` with
    `-only-testing:PerformanceTests/PerformanceBudgetTests/testTypingLatencyStaysUnderFrameBudget`
    and
    `-only-testing:PerformanceTests/AppBackedEditorPerformanceTests/testHostedPublicEditorCurrentRevisionInputAndMarkedTextStayWithinFrameBudget`.
  - Odd pairs run `main` first and even pairs run B2 first.
- Result: pass. All 24 test runs passed and every sample is under 16 ms. The paired
  differences change sign, and no metric moved beyond its run-to-run spread.

Why it was measured: each published editor source checks `isAuthorizedEditorDocumentBinding`,
which calls `isManagedEditorSession`. Before B2 that compared the session with the current
document. B2 asks the registry whether any connected window shows it
(`AppDocumentRegistry.isShownByAnyWindow`), which walks the registered windows (one, until PR C).
B2 adds no `@Published` property and no publish.

## App-backed hosted typing (goes through `AppState`)

Each value is the single timed native insertion plus public-view update that the test prints,
in ms. The load column gives the 1-minute load at the start of the pair's first and second run.

| Pair (order) | Load | `main` ordinary | B2 ordinary | `main` pair | B2 pair | `main` marked max | B2 marked max |
|---|---|---:|---:|---:|---:|---:|---:|
| 1 (main, B2) | 10.25 / 9.99 | 8.320 | 6.322 | 7.412 | 7.806 | 10.865 | 6.936 |
| 2 (B2, main) | 9.99 / 9.83 | 7.728 | 8.248 | 6.553 | 7.604 | 6.591 | 7.758 |
| 3 (main, B2) | 12.01 / 12.01 | 6.333 | 9.227 | 8.159 | 7.097 | 6.527 | 7.056 |
| 4 (B2, main) | 11.37 / 11.37 | 8.691 | 7.501 | 7.263 | 8.111 | 6.959 | 5.352 |
| 5 (main, B2) | 11.42 / 11.46 | 9.020 | 8.734 | 7.680 | 6.828 | 7.062 | 7.416 |
| 6 (B2, main) | 11.46 / 11.99 | 8.319 | 8.661 | 6.948 | 7.349 | 6.744 | 6.444 |
| Median | | 8.320 | 8.454 | 7.338 | 7.476 | 6.851 | 6.996 |
| Paired B2 − `main`, mean (range) | | | +0.047 (−1.998 to +2.894) | | +0.130 (−1.062 to +1.051) | | −0.631 (−3.929 to +1.167) |

## §12 typing test (EditorKit only; a control)

The value is the per-scenario maximum the test prints, in ms; each list holds the six runs.

| Scenario | `main` | B2 |
|---|---|---|
| markdown plain (200) | 0.003 0.002 0.003 0.003 0.002 0.003 | 0.003 0.010 0.003 0.003 0.004 0.003 |
| markdown newline (200) | 0.095 0.050 0.043 0.042 0.043 0.045 | 0.085 0.044 0.047 0.055 0.040 0.042 |
| markdown pair (50) | 0.318 0.307 0.173 0.282 0.197 0.196 | 0.279 0.224 0.160 0.170 0.313 0.156 |
| mdx plain (200) | 0.001 0.001 0.002 0.001 0.003 0.002 | 0.001 0.002 0.021 0.001 0.001 0.001 |
| mdx jsx trigger (50) | 0.241 0.202 0.157 0.131 0.232 0.213 | 0.177 0.129 0.170 0.130 0.142 0.382 |

The app-backed test takes one sample per run, so six pairs bound a regression only to about
the ±2–3 ms spread seen here. These are Debug numbers under load, not a Release or idle
measurement. W12 (typing with four windows) stays a separate gate.
