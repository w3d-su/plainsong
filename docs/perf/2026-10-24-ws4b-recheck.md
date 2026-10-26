# WS4B workspace-search probes re-checked at the Workspace Search DoD close-out

- Date: 2026-10-24
- Commit: `3ae52db` (`main` at `1428bf1` plus the hidden-sidebar ⇧⌘F fix, which touches no
  search, read or match code)
- Environment: macOS 27.0 (26A428), Xcode 27.0 (27A5194q), Apple M1 Pro, Debug
- Fixture: the WS4B fixtures in `PerformanceTests/WorkspaceSearch*` (archive section "Phase 3
  WS4B Workspace Search Performance Gates" in `docs/perf-log.md`); budgets unchanged
- Procedure: three dedicated runs of
  `xcodebuild -project Plainsong.xcodeproj -scheme Plainsong -configuration Debug
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/plainsong-wsdod-debug
  -only-testing:PerformanceTests/WorkspaceSearchPerformanceTests test-without-building`
  against the product the passing `make test` built, back to back, 14:59-15:01 local. No other
  `xcodebuild`, `swift-build` or `swift-frontend` process ran; 1-minute load 13.1, 26.7 and
  37.3 at the start of runs 1-3 (StorageManagement and WindowServer were the top processes)
- Result: 14/14 tests passed in each run; every median is under its frozen budget (pass)

| Metric | Budget | Run 1 | Run 2 | Run 3 | Headroom |
|---|---:|---:|---:|---:|---:|
| Workspace search, 2,000 files (`.sensitive`) | < 3,000 ms | 963.039 | 975.796 | 968.614 | 3.1x |
| Workspace search, 2,000 files (`.smart`) | < 4,000 ms | 954.923 | 972.857 | 1051.012 | 3.8x |
| Admitted 524,288-byte file | < 150 ms | 40.767 | 38.774 | 38.756 | 3.7x |
| Admitted 524,288-byte CJK file (`.smart`) | < 150 ms | 26.002 | 25.890 | 31.446 | 4.8x |
| Dense whole-word `ascii-suffix` | < 200 ms | 48.069 | 46.714 | 47.616 | 4.2x |
| Dense whole-word `unicode-periodic` | < 2,500 ms | 702.127 | 669.780 | 821.285 | 3.0x |
| Cancel-to-drain, saturated 4-read window | < 50 ms | 0.207 | 0.177 | 0.170 | 241x |

Values are the per-run medians in milliseconds that the probes print. Headroom is the budget
divided by the slowest of the three medians, as in the archive.

The same 14 probes also passed inside the serialized `make test` that closed the Definition of
Done (14:36-14:52, load 26-121 while the hosted bundles ran). That run printed 1160.516 ms for
the 2,000-file `.sensitive` search (samples 1722.637, 1160.516, 1083.271) and 676.521 ms for
`unicode-periodic`; the dedicated runs above are the comparable numbers. Against the archive's
2026-07-26 Debug medians, nothing regressed: the 2,000-file searches are 6-10% faster and
`unicode-periodic` 20-35% faster, which matches the whole-word work recorded after the
gates were frozen; the other metrics are within run-to-run noise. Absolute values from
different sessions and loads are not a paired comparison.
