# Opening large Markdown files in a macOS workspace window

- Date: 2026-11-18
- Commit: `53b6cefe` for the verification below. The original opening comparison used
  `2af666cb` as its baseline and the implementation in `5204ca21` for deferred counting.
- Environment: arm64 MacBook Pro, macOS 27.0 (26A428), Xcode 27.0 (27A5194q), Release.
- Fixture: `Fixtures/perf-500kb.md` for the §12 load-and-paint budget of < 300 ms.
  The hosted probes use `Fixtures/large-1mb.md`, a Traditional Chinese paragraph
  repeated to 1 MiB, and ten copies of the English fixture for 10 MiB.
- Procedure: run the Release tests below three times with a warm local filesystem cache.
- Result: **PASS**. The 500 KB load-and-paint samples were 35.678, 29.044 and
  29.259 ms (median 29.259 ms). All three were below 300 ms.

## Verification after moving the count into the document session

At `53b6cefe`, the 10 MiB hosted probe took 60.71, 55.80 and 50.22 ms from Open
to AppKit display (median 55.80 ms). The same runs took 112.30, 103.22 and 97.04 ms
through the first native insertion and display (median 103.22 ms). The §12 budget
applies to the 500 KB fixture. The 10 MiB probe has no timing threshold.

The cached sidebar switch, simultaneous edits in separate windows, and Save As
each passed three hosted Release runs. Each test waits for the edited session's
counts. The Save As test also reads both files to verify their contents.

## Original opening comparison

For the 1 MiB files, both builds ran the same timing probe three times,
with baseline runs first. Each sample used a fresh source-only window, session and
temporary local file. The file was written just before opening, so these are warm
filesystem-cache measurements.

The English source is `Fixtures/large-1mb.md` (1,048,962 UTF-8 bytes). The Traditional
Chinese source repeats the paragraph in the test to 1,048,870 bytes.

| Source and entry point | Median open to AppKit display (ms), before → after | Median open to first edit and display (ms), before → after |
| --- | ---: | ---: |
| English, Open | 68.39 → 22.52 | 80.57 → 34.94 |
| English, Files sidebar | 94.28 → 40.00 | 107.63 → 53.59 |
| Traditional Chinese, Open | 202.47 → 24.00 | 213.44 → 35.14 |
| Traditional Chinese, Files sidebar | 225.98 → 43.58 | 240.53 → 57.15 |
| English, 10 MiB, Open | 524.15 → 55.64 | 566.26 → 98.50 |

For 10 MiB, both native arm64 Release builds used ten copies of the English fixture
(10,489,620 bytes). Each ran three times in paired order, old/new, new/old, old/new.
Old display samples were 512.44, 533.48 and 524.15 ms. New samples were 99.22, 55.64
and 51.36 ms. First-edit samples in the same order were 554.86, 577.45 and 566.26 ms
before and 144.07, 98.50 and 93.76 ms after. The first insertion and its display pass
still took 42–45 ms after the initial display at this size.

Timing begins at the file-open handler after URL selection, or at the Files sidebar's
deferred selection handler. The first interval ends when the production editor has
the new text storage length, accepts edits, and its window returns from
`displayIfNeeded()`. The second interval ends after an insertion through the native
editor and a second display pass. The test checks the destination session and edited
source. Physical key delivery, compositor presentation, file-picker interaction,
recent-item persistence and preview rendering are outside these intervals.

The sidebar has more scheduling variance. Its three Traditional Chinese display samples
were 266.64, 225.98 and 222.25 ms before and 42.41, 87.42 and 43.58 ms after.
The structural regression assertion checks that the new session reaches the real
window with initial counts pending. The existing 500 KB load-and-paint gate measured
38.469 ms against its 300 ms budget in the original Release verification. The existing
native typing hot-path probe measured at most 0.225 ms across its five scenarios.

## Reproduction

Run `make generate` and then run the probes from the project root.

```sh
xcodebuild -project Plainsong.xcodeproj -scheme PerformanceTests -configuration Release \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
  -only-testing:PerformanceTests/PerformanceBudgetTests/testOpening500KBMarkdownToEditorFirstPaintStaysUnderBudget \
  -only-testing:PerformanceTests/AppBackedEditorPerformanceTests/testLargeFileOpenToHostedDisplayAndFirstEdit \
  -only-testing:PerformanceTests/AppBackedEditorPerformanceTests/testTenMiBFileOpenToHostedDisplayAndFirstEdit \
  -test-iterations 3 ENABLE_TESTABILITY=YES test
```
