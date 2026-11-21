# iOS Replace All: main-actor cost today

- Date: 2026-11-21
- Commit: measured on `28e1b93` with only the probe added (no production change).
- Environment: one macOS 26.6.2 VM (Apple M4 Pro, virtual, 12 CPUs, 16 GiB), Xcode 26.6
  (17F113). Simulators: iPhone 17 Pro and iPhone 17, both iOS 26.5. Debug configuration
  with `SWIFT_OPTIMIZATION_LEVEL=-O` for every target (the Release test bundle does not link
  on this Xcode because of an unrelated SwiftUI symbol in `IOSFormattingActionTests`).
  No second Mac was available, so both columns below come from the same host.
- Probe: `AppIOSTests/PerformanceProbe/IOSReplaceAllMainActorProbeTests.swift`. It builds
  a real `IOSSourceEditorController` (production `MarkdownSyntaxTokenizer`) in a window,
  runs the real find query for `alpha`, then times `IOSAuthoringController.perform(.replaceAll)`
  replacing every match with `omega`. Pure phases are timed separately on the same input.
  One warm-up then 5 repetitions per row; medians below. The fixture has 64-byte lines,
  so 256 KiB holds only 4,096 lines and its 10,000-match row is skipped.
- Run: `TEST_RUNNER_PROBE_REPS=5 xcodebuild test … -only-testing:PlainsongIOSTests/IOSReplaceAllMainActorProbeTests`.
  Without `TEST_RUNNER_PROBE_REPS` the probe skips, so normal test runs pay nothing.

## Result

Replace All blocks the main actor for about 11 ms at 256 KiB, 27–33 ms at 1 MiB and
93–109 ms at 4 MiB. Time grows with document size, barely with match count.

At 4 MiB the time splits roughly like this:

| Phase | ms at 4 MiB | Runs |
| --- | ---: | --- |
| Full-text equality checks | ~60 | 3 per Replace All: two in `IOSSourceEditorController.refusal(for:)` before the edit, one `ExactSourceText.matches(latest, post)` after it |
| Find rescan (`EditorReplaceContinuationPlanning.afterBatch`) | ~22 | once |
| UIKit edit + `publishCurrentText` + highlight/snapshot scheduling | ~10–20 | once |
| String building (`replacedSlice` + `replacedSource`) | 2–8 | once |
| Planning (`EditorReplacePlanner.planBatch`) | ≤1 | once |

Median ms, iPhone 17 Pro simulator (iPhone 17 in brackets):

| Size | Matches | Total on main | `apply` (whole) | One guard compare | Rescan | Post-write compare | Slice + source build | Plan |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 256 KiB | 2 | 10.1 [10.7] | 7.3 [7.4] | 1.3 [1.4] | 1.4 [1.5] | 1.3 [1.4] | 0.1 [0.2] | 0.0 |
| 256 KiB | 1,000 | 11.7 [10.9] | 8.0 [7.3] | 1.4 [1.4] | 1.4 [1.4] | 1.3 [1.3] | 0.8 [0.7] | 0.1 |
| 1 MiB | 2 | 28.0 [27.3] | 16.7 [15.6] | 5.2 [5.0] | 5.5 [5.7] | 5.2 [5.3] | 0.5 [0.6] | 0.0 |
| 1 MiB | 1,000 | 31.5 [29.2] | 18.8 [17.0] | 5.5 [5.7] | 5.4 [5.9] | 5.3 [5.3] | 1.3 [1.5] | 0.2 |
| 1 MiB | 10,000 | 33.2 [32.6] | 16.6 [16.7] | 5.5 [5.3] | 6.0 [5.9] | 5.3 [5.0] | 4.6 [4.8] | 0.7 |
| 4 MiB | 2 | 93.0 [95.3] | 50.3 [51.7] | 19.5 [20.2] | 22.4 [23.8] | 19.8 [20.4] | 1.6 [1.7] | 0.0 |
| 4 MiB | 1,000 | 109.2 [109.0] | 59.8 [60.5] | 20.5 [19.6] | 21.7 [21.2] | 20.2 [20.6] | 4.4 [7.9] | 0.1 |
| 4 MiB | 10,000 | 108.7 [106.0] | 57.7 [56.7] | 20.1 [19.7] | 22.0 [21.6] | 20.7 [18.7] | 7.6 [7.2] | 1.0 |

Columns: *Total* is wall time of the synchronous `perform(.replaceAll)` call. *`apply`* is
the whole `IOSSourceEditorController.apply` call. *One guard compare* is one
`textStorage.string` read plus the literal `NSString.compare` that `refusal(for:)` runs; `apply`
runs it twice on the unchanged text, so `apply` minus two guards is the UIKit edit plus
`publishCurrentText` (its own compare exits at the first difference). *Rescan* and
*Post-write compare* are timed by the probe on the same inputs, because they run inside
`perform`. Worst single run: 110 ms (4 MiB).

## Reading

- Moving only the string building off the main actor would save at most ~8 ms at 4 MiB
  and ~5 ms at 1 MiB; it would not remove the stall.
- The largest cost is full-document comparison: three literal compares of the whole text
  (~20 ms each at 4 MiB, ~5 ms at 1 MiB), more than half of the total. The native UIKit
  edit itself is ~10–20 ms at 4 MiB.
- Next is the post-write rescan (~22 ms at 4 MiB), which could run off main.
- At 1 MiB (the §1 typing target) a Replace All costs about two frames at 60 Hz; at
  4 MiB about six.
