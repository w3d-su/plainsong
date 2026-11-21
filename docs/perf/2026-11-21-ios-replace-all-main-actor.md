# iOS Replace All: main-actor cost today

- Date: 2026-11-21
- Commit: measured on `28e1b93` with only the probe added (no production change).
- Environment: one macOS 26.6.2 VM (Apple M4 Pro, virtual, 12 CPUs, 16 GiB), Xcode 26.6
  (17F113). Simulators: iPhone 17 Pro and iPhone 17, both iOS 26.5. Debug configuration
  with `SWIFT_OPTIMIZATION_LEVEL=-O` for every target (the Release test bundle does not link
  on this Xcode because of an unrelated SwiftUI symbol in `IOSFormattingActionTests`).
  No second Mac was available, so both rows below come from the same host.
- Probe: `AppIOSTests/PerformanceProbe/IOSReplaceAllMainActorProbeTests.swift`. It builds
  a real `IOSSourceEditorController` (production `MarkdownSyntaxTokenizer`) in a window,
  runs the real find query for `alpha`, then times `IOSAuthoringController.perform(.replaceAll)`
  replacing every match with `omega`. Pure phases are timed separately on the same input.
  One warm-up then 5 repetitions per row; medians below. The fixture has 64-byte lines,
  so 256 KiB holds only 4,096 lines and its 10,000-match row is skipped.
- Run: `TEST_RUNNER_PROBE_REPS=5 xcodebuild test … -only-testing:PlainsongIOSTests/IOSReplaceAllMainActorProbeTests`.
  Without `TEST_RUNNER_PROBE_REPS` the probe skips, so normal test runs pay nothing.

## Result

Replace All blocks the main actor for about 10 ms at 256 KiB, 30–39 ms at 1 MiB and
105–126 ms at 4 MiB. Time grows with document size, barely with match count. Building
the replacement strings (`replacedSlice` + `replacedSource`) is at most ~8 ms of that
(4 MiB, 10,000 matches); the rest is the native UIKit edit, the post-write find rescan
and the post-write exact-text comparison, which run whatever the match count.

Median ms, iPhone 17 Pro simulator (iPhone 17 in brackets):

| Size | Matches | Total on main | Native apply | Rescan (`afterBatch`) | Post-write compare | Slice + source build | Plan |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 256 KiB | 2 | 9.7 [10.8] | 6.8 [7.8] | 1.6 [1.5] | 1.2 [1.4] | 0.2 [0.2] | 0.0 |
| 256 KiB | 1,000 | 11.2 [11.0] | 7.6 [7.3] | 1.6 [1.3] | 1.3 [1.3] | 0.7 [0.6] | 0.1 |
| 1 MiB | 2 | 29.6 [30.1] | 17.1 [17.9] | 7.2 [5.9] | 5.4 [5.2] | 0.5 [0.5] | 0.0 |
| 1 MiB | 1,000 | 34.4 [32.6] | 19.2 [19.6] | 7.4 [6.1] | 5.3 [5.3] | 1.6 [1.4] | 0.1 |
| 1 MiB | 10,000 | 38.6 [35.1] | 18.0 [17.7] | 7.8 [6.2] | 5.5 [5.3] | 5.1 [5.2] | 0.7 |
| 4 MiB | 2 | 111.5 [104.7] | 56.9 [56.2] | 29.9 [23.5] | 21.2 [20.8] | 3.8 [1.8] | 0.0 |
| 4 MiB | 1,000 | 118.2 [118.5] | 62.4 [64.0] | 29.6 [23.4] | 20.1 [22.0] | 5.3 [6.7] | 0.1 |
| 4 MiB | 10,000 | 125.6 [116.3] | 63.3 [60.5] | 29.8 [23.8] | 22.3 [21.2] | 8.6 [7.9] | 0.8 |

Columns: *Total* is wall time of the synchronous `perform(.replaceAll)` call. *Native apply*
is `IOSSourceEditorController.apply` (UIKit replace plus `publishCurrentText`).
*Rescan* is `EditorReplaceContinuationPlanning.afterBatch` and *Post-write compare* is
the `ExactSourceText.matches(latest, post)` check after the edit; both are timed by the
probe on identical inputs, because they run inside `perform`. Worst single run: 132 ms
(4 MiB, 2 matches).

## Reading

- Moving only the string building off the main actor would save at most ~8 ms at 4 MiB
  and ~5 ms at 1 MiB; it would not remove the stall.
- At 1 MiB (the §1 typing target) a Replace All costs about two frames at 60 Hz; at
  4 MiB about seven. Most of it is the UIKit text-storage edit, which must stay on main.
- The cheaper wins, if any are wanted, are the two full-document passes after the edit
  (rescan ~24–30 ms and exact compare ~21 ms at 4 MiB).
