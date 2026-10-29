# Windows D1c typing stays within the run-to-run spread

- Date: 2026-10-30
- Commit: measured `f80b0302` against `main` at `17949106`. Rebase onto D1b
  `e7eaa94e` rewrote that commit; it is not on the branch. Current head is
  `cff0cafc`. Typing was not remeasured. The measured tree had uncommitted
  documentation and no dirty Swift source. The later registration narrowing is
  outside the keystroke path and was not in that binary.
- Environment: macOS 27.0 (26A428), Xcode 27.0 (27A5194q), Apple M1 Pro, Debug.
  Every run started with `IOConsoleLocked=Yes` and `CGSSessionScreenIsLocked=Yes`.
  The 1-minute load was 2.91–3.35, below the earlier 6–8 comparison load. No extra
  load was added and no run was discarded.
- Fixture: `Fixtures/large-1mb.md`. Budget: `agent.md` §12 typing < 16 ms.
- Products: `test-without-building` used each tree's own DerivedData. The xctestrun
  plists hash to the same `5735b336e00a498f67022b51bf4dae3afc20f40ff0de9f0a2b407d49ced7afca`
  because they use `__TESTROOT__`. The launched bundles differ:
  main app `e2a6014ee796559bd019d83a3535d71dcf0f80db4f0e4e2d3bbed67e6addcb95`,
  main PerformanceTests `c5793386fdfd673d85dea65ee06fdd6e0cebed7f1861602e5b915c30848eb3b5`,
  D1c PerformanceTests `1f34ea751b72327d7b00ec832502e94af3923a0ceed215e8c0ba5940ac93441b`.
  The measured D1c app SHA-256 began `f08927d0bc8bfd02`; a later lifecycle rebuild
  replaced that product, so the full measured digest was not retained.
- Procedure: six interleaved pairs. Odd pairs run `main` then D1c; even pairs run
  D1c then `main`. Each run executes
  `PerformanceTests/PerformanceBudgetTests/testTypingLatencyStaysUnderFrameBudget`
  and
  `PerformanceTests/AppBackedEditorPerformanceTests/testHostedPublicEditorCurrentRevisionInputAndMarkedTextStayWithinFrameBudget`.
- Result: pass. All 24 named tests passed and every sample is under 16 ms. Paired
  differences change sign and stay inside the run-to-run spread. This does not
  close four-window W12 or Release/residency acceptance; those remain G.

Why it was measured: D1c shares one root snapshot, watcher and scan, and transfers
writer authority when another window adopts a warm session. Body edits do not
publish or scan the peer (`WindowSharedRootAppTests/testBodyEditsDoNotFanOutPublishesOrScansToTheOtherWindow`,
200 edits, zero peer publishes and zero scans). Adoption still does an O(1)
superseded-writer lookup; that is not a claim of zero added instructions.

## App-backed hosted typing (goes through `AppState`)

Each value is the single timed native insertion plus public-view update that the test prints,
in ms. The load column is the 1-minute load at the start of that pair's first and second run.

| Pair (order) | Load | `main` ordinary | D1c ordinary | `main` pair | D1c pair | `main` marked max | D1c marked max |
|---|---|---:|---:|---:|---:|---:|---:|
| 1 (main, D1c) | 3.23 / 3.29 | 9.386 | 9.045 | 5.769 | 7.420 | 5.892 | 6.674 |
| 2 (D1c, main) | 3.29 / 3.35 | 9.604 | 9.624 | 7.739 | 7.692 | 6.586 | 5.275 |
| 3 (main, D1c) | 3.35 / 3.16 | 7.603 | 9.751 | 8.050 | 6.039 | 6.916 | 5.302 |
| 4 (D1c, main) | 2.91 / 2.91 | 9.736 | 7.352 | 6.008 | 7.909 | 7.310 | 6.678 |
| 5 (main, D1c) | 2.91 / 2.91 | 8.890 | 9.068 | 7.247 | 7.126 | 6.453 | 6.414 |
| 6 (D1c, main) | 3.16 / 3.15 | 9.170 | 8.686 | 6.019 | 6.676 | 5.296 | 6.676 |
| Median | | 9.278 | 9.057 | 6.633 | 7.273 | 6.520 | 6.544 |
| Paired D1c − `main`, mean (range) | | | −0.144 (−2.384 to +2.148) | | +0.338 (−2.011 to +1.901) | | −0.239 (−1.614 to +1.380) |

## §12 typing test (EditorKit only)

The value is the per-scenario maximum the test prints, in ms; each list holds the six runs in pair order.

| Scenario | `main` | D1c |
|---|---|---|
| markdown plain (200) | 0.003 0.003 0.002 0.002 0.003 0.002 | 0.002 0.003 0.003 0.003 0.003 0.002 |
| markdown newline (200) | 0.085 0.041 0.052 0.049 0.046 0.044 | 0.079 0.042 0.041 0.038 0.039 0.041 |
| markdown pair (50) | 0.169 0.162 0.158 0.167 0.167 0.166 | 0.153 0.158 0.159 0.159 0.156 0.156 |
| mdx plain (200) | 0.001 0.001 0.001 0.003 0.006 0.005 | 0.007 0.001 0.001 0.001 0.001 0.001 |
| mdx jsx trigger (50) | 0.132 0.137 0.140 0.130 0.140 0.133 | 0.201 0.131 0.134 0.139 0.143 0.133 |

The app-backed test takes one sample per run, so six pairs only bound a regression to about
the ±2.4 ms spread seen here. The screen was locked for every run, so these absolute times
are not comparable to the unlocked 6–8 load records. Both sides ran under that same lock.
Logs and `results.json` are in `/tmp/plainsong-d1c-evidence/typing-ab/`.

Executable SHA-256 at measurement:

- `main` app: `e2a6014ee796559bd019d83a3535d71dcf0f80db4f0e4e2d3bbed67e6addcb95`
- `main` PerformanceTests: `c5793386fdfd673d85dea65ee06fdd6e0cebed7f1861602e5b915c30848eb3b5`
- D1c PerformanceTests: `1f34ea751b72327d7b00ec832502e94af3923a0ceed215e8c0ba5940ac93441b`
- D1c app: prefix `f08927d0bc8bfd02` (full digest not retained; see above)
