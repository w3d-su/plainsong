# M5 Performance Log

Record M5 performance measurements here before accepting the milestone. Each entry should identify
the commit, environment, fixture, measurement procedure, measured value, and pass/fail result. Keep
raw profiler exports or screenshots outside the repo unless they are small and intentionally useful.

## Environment

| Field | Value |
|---|---|
| Date | 2026-06-17 |
| Commit | Measured code commit `bd86dc37bcbf5de91b0f20fe5182e7a11e7fe27d` |
| macOS | macOS 27.0 (26A5353q) |
| Xcode | Xcode 27.0 (27A5194q) |
| Machine | Apple M1 Pro, arm64, 16 GB RAM |
| Build configuration | `Debug`; `make test` / Xcode scheme `Plainsong` |
| Notes | Evidence: Xcode result bundle `~/Library/Developer/Xcode/DerivedData/Plainsong-awqexsyzmttqfhcfdgdaneqwnuwq/Logs/Test/Test-Plainsong-2026.06.17_16-49-55-+0800.xcresult`; signpost subsystem `app.plainsong.performance`, category `M5`. |

## Issue #14 Highlight Gate Environment

| Field | Value |
|---|---|
| Date | 2026-06-24 |
| Commit | PR #20 commit `ff17fe8` after rebasing onto `main` |
| macOS | macOS 27.0 (26A5353q) |
| Xcode | Xcode 27.0 (27A5194q) |
| Machine | Apple M1 Pro, arm64, 16 GB RAM |
| Build configuration | `Debug`; Xcode scheme `Plainsong` |
| Notes | Evidence: Xcode result bundle `~/Library/Developer/Xcode/DerivedData/Plainsong-ewedbdrqcwagpxgzdhgoznouomjz/Logs/Test/Test-Plainsong-2026.06.24_04-17-41-+0800.xcresult`; signposts `VisibleRangeHighlightMarkdown1MB` and `VisibleRangeHighlightMDX1MB`. |

## Issue #13 Memory Gate Environment

| Field | Value |
|---|---|
| Date | 2026-06-24 |
| Commit | PR #21 commit `cf48820`, merged into PR #20 and included on `main` |
| macOS | macOS 27.0 (26A5353q) |
| Xcode | Xcode 27.0 (27A5194q) |
| Machine | Apple M1 Pro, arm64, 16 GB RAM |
| Build configuration | `Debug`; `make test` / Xcode scheme `Plainsong` |
| Notes | Evidence: Xcode result bundle `~/Library/Developer/Xcode/DerivedData/Plainsong-cvprtqeandytbnbtdhosatlmfslj/Logs/Test/Test-Plainsong-2026.06.24_04-20-43-+0800.xcresult`. |

## Summary

| Metric | Budget | Measured | Result | Procedure |
|---|---:|---:|---|---|
| Typing latency | < 16 ms | 0.254 ms max | Pass | See [Typing Latency](#typing-latency) |
| Highlight update visible range | < 50 ms | Markdown 17.918 ms max; MDX 22.670 ms max | Pass | See [Highlight Update](#highlight-update) |
| Preview render, 100 KB document | < 100 ms after debounce | Markdown 46.631 ms median; MDX 14.556 ms median | Pass | See [Preview Render](#preview-render) |
| File open, 500 KB Markdown | < 300 ms to first paint | 33.765 ms | Pass | See [File Open](#file-open) |
| Memory with 8 warm sessions + 2 webviews | < 400 MB host-process RSS | 149.8 MB host RSS with 2 settled webviews | Pass | See [Memory](#memory) |

## Final Checklist Verification Run

| Field | Value |
|---|---|
| Date | 2026-06-25 |
| Branch | `m5-final-checklist-docs` |
| Commit | Working tree after the scroll-sync checklist fix on `m5-final-checklist-docs` |
| Result | Automated performance gates passed. At this run, M5 remained feature-complete but not accepted because manual checklist blockers remained in `docs/m5-checklist.md`; later PR #33 supplied the final editor-input evidence and accepted M5. |

Current sweep values from `make test`:

| Metric | Current sweep value | Result |
|---|---:|---|
| Typing latency | 0.309 ms max | Pass |
| Highlight update visible range | Markdown 15.876 ms max; MDX 22.189 ms max | Pass |
| Preview render, 100 KB document | Markdown 62.257 ms median; MDX 15.343 ms median | Pass |
| Memory with 8 warm sessions + 2 webviews | 141.6 MB host RSS; WebKit helpers 498.1 MB across 2 helpers, aggregate 639.7 MB diagnostic | Pass |

## Phase 2 WYSIWYG Zero-width Mechanism Verification

| Field | Value |
|---|---|
| Date | 2026-06-26 |
| Branch | `phase2-wysiwyg-zerowidth-mechanism` |
| Commit | Working tree after replacing the baseline-offset fold mechanism with the TextKit 2 content-storage projection |
| Command | `swift test --filter MarkdownEditorViewTests/testWYSIWYGVisibleRangeFoldRecomputeStaysUnderHighlightBudget` after full `make test` |
| Fixture | `Fixtures/large-1mb.md`, visible-range WYSIWYG fold/highlight/apply path |
| Budget | <= 50 ms |
| Measured | `WYSIWYG visible-range fold highlight/apply: 26.964 ms` |
| Result | Pass |
| Notes | This run verifies B10 in `docs/wysiwyg-release-checklist.md` against the replacement zero-width mechanism. The projection keeps the backing Markdown string canonical and collapses folded delimiter layout without the old `baselineOffset(-1000)` line-height inflation. |

## Phase 2 Link Folding Native Gate Verification

| Field | Value |
|---|---|
| Date | 2026-07-06 |
| Branch | `phase2-link-folding-native-gates` |
| Commit | Working tree for link-folding PR B after PR #65 merged |
| Command | `swift test --package-path Packages/EditorKit --filter WYSIWYG` |
| Fixture | Unmodified `Fixtures/large-1mb.md`; its existing repeated sections already contain inline links |
| Presentation | `.inlineFoldRevealWithLinkFolding` through the TextKit 2 content-storage projection |
| Budget | <= 50 ms |
| Measured | `16.968 ms` max; samples `[16.968, 16.003, 16.134]` after one warm-up |
| Result | Pass |
| Notes | `WYSIWYGLinkPerformanceGateTests.testL8LinkFoldingVisibleRangeRecomputeStaysUnderFiftyMilliseconds` measures visible-range parse, link fold-plan/presentation, in-place attribute apply, and display. The fixture and generator were not changed. |

## Phase 2 Image Thumbnail Native Gate Verification (I8)

| Field | Value |
|---|---|
| Date | 2026-07-11 |
| Branch | `phase2-image-thumbnail-gates` |
| Commit | Working tree for image-thumbnail native gates (I3/I4/I6/I7/I8/I9) after PR #80 |
| Command | `swift test --package-path Packages/EditorKit --filter WYSIWYGImageThumbnail` |
| macOS | macOS 27.0 (26A5378j) |
| Xcode | Xcode 27.0 (27A5194q) |
| Machine | Apple silicon arm64, 16 GB RAM |
| Fixture | Unmodified `Fixtures/large-1mb.md` (already contains `![sample](./assets/image-NNNNN.png)` per section; no fixture generator change) |
| Presentation | Internal `_developmentImageThumbnails` hook + `.inlineFoldRevealWithLinkFolding` |
| Budget | Visible-range recompute ≤ 50 ms (hard locally, CI-informational per R15); typing < 16 ms while loads in flight |
| Measured recompute | `15.234 ms` max; samples `[14.806, 14.815, 14.711, 14.985, 15.234]` after two warm-ups |
| Measured typing | `0.002 ms` max in-flight typing hot path on large-1mb.md |
| Loader cache budget | `32 MiB` (`WorkspaceImageThumbnailProvider.defaultCacheByteBudget = 32 * 1024 * 1024`) |
| Result | Pass |
| Notes | `WYSIWYGImageThumbnailI8PerformanceGateTests.testI8VisibleRangeRecomputeWithImageFoldingStaysUnderFiftyMilliseconds` measures post-edit visible-range parse/fold (incl. image regions), highlight attribute apply (preserving image markers), image-marker presentation apply, and display. Decode isolation asserted by `testI8LoaderDecodePathRunsOffMainThread`. Production fix: image presentation source identity no longer walks full UTF-16 of multi-MB documents on every apply. |

## Phase 3 WS4B Workspace Search Performance Gates

| Field | Value |
|---|---|
| Date | 2026-07-25; re-measured 2026-07-26 after the review-hardening pass |
| Branch | `phase3-search-ws4b-performance-gates`; originally branched from `main` at `fe953db`, then merged `main` at `58740ac` (PR #94) |
| Commit | Debug and Release re-measurement at the review-hardening tip described in "2026-07-26 re-measurement" below. Only this section's prose changed after those runs; no Swift source was touched afterwards. |
| macOS | Darwin 27.0.0 |
| Machine | Apple Silicon, arm64, 16 GB RAM |
| Test files | `PerformanceTests/WorkspaceSearchPerformanceTests.swift` (probes and frozen constants), plus `…SmartCasePerformanceTests`, `…CeilingPerformanceTests`, `…CancellationPerformanceTests`, `…PerformanceFixtures`, `…PerformanceAssertions`, `…PerformanceSupport`, `…PerformanceBlockingReader`. Split from one 1,258-line file to keep each under the ~400-line guidance in agent.md §17.10. |
| Probe count | 10 tests (5 at the original freeze, then +2 for the resource-ceiling pins and global match ceiling, then +3 for the default `.smart` case path) |
| Local Release command | `xcodebuild -project Plainsong.xcodeproj -scheme Plainsong -configuration Release -derivedDataPath ~/Library/Developer/Xcode/DerivedData/plainsong-ws4b-release ENABLE_TESTABILITY=YES -only-testing:PerformanceTests/WorkspaceSearchPerformanceTests test` |
| Local Debug command | `xcodebuild -project Plainsong.xcodeproj -scheme Plainsong -configuration Debug -derivedDataPath ~/Library/Developer/Xcode/DerivedData/plainsong-ws4b-debug -only-testing:PerformanceTests/WorkspaceSearchPerformanceTests test` |
| Reproducibility | Reproducible as written. Both commands above run at this branch tip with no build-setting override. Before PR #94 was merged the Release command exited 65 here, because `AppTests` referenced App probes that exist only under `#if DEBUG` and `xcodebuild` builds every test target even under `-only-testing`; merging `main` at `58740ac` removed that. Three Release runs were performed after the merge — see "Post-#94 Release re-verification" below. |
| Measurement provenance | The budget-selection medians tabulated below were taken **before** PR #94, when the Release test build still required `SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) DEBUG'`. They are retained as the record of how the budgets were chosen. They are no longer the only Release evidence: the post-#94 re-verification below re-measured every metric with the override gone and landed inside the same ranges, which confirms empirically what was previously only argued — the override changed no optimization level (`-O` either way) and could not reach the measured path, since `Packages/MarkdownCore` and `Packages/WorkspaceKit` contain no `#if DEBUG` code. |

### Procedure

1. Every probe drives the real `WorkspaceSearchService` over a real on-disk workspace. The four
   search probes use the production `WorkspaceSearchDiskFileReader`, so the measurement includes
   candidate planning, ignore-policy probes, anchored no-follow reads, UTF-8 decoding,
   MarkdownCore matching, snippet construction, and stream delivery. The cancellation probe is
   the one deliberate exception: it substitutes a controlled reader that blocks every candidate
   read, because a deterministic cancel-to-drain measurement needs a saturated read window that
   cannot finish on its own. Its `.gitignore` / `.ignore` probes still resolve as missing exactly
   as they do against the real fixture, so only candidate reads are controlled.
2. Fixture creation and `WorkspaceDirectoryScanner.snapshotCapture` run before timing starts and
   are never inside a measured region.
3. Each timed search probe runs one unmeasured warm-up request, then three measured requests. The
   warm-up is asserted with the same deterministic predicates as the measured samples, so a
   warm-up that searched nothing cannot make later samples cheap. The cancellation probe has no
   warm-up; it repeats five independent cancellations and reports their median.
3a. A separate one-per-process warm-up (`WorkspaceSearchPerformanceWarmUp`, invoked from
   `setUp()`) runs a bounded search over a small workspace before any probe executes. It absorbs
   process start-up — dyld, Foundation/ICU initialization, first task-group construction, CPU
   frequency ramp — which the per-probe warm-up cannot, because that cost is paid once per
   process and lands entirely on whichever probe runs first. See the cold-start finding below.
4. Every sample hard-asserts the ordered result set, per-file match ranges/lines, exact summary
   accounting, exact event counts, and read-window ceilings. Timing is only recorded after those
   assertions hold. Every run that reaches completion — measured sample, warm-up, and the
   dense-rejection literal control alike — is put through the shared
   `assertSharedStreamInvariants` helper, so the exact event count, progress coalescing,
   read-window ceilings, skipped-detail cap, and completion ordering are checked on all of them
   rather than on the bulk probe only.
5. The resource ceilings are pinned as literals in the test file, not read back from
   `WorkspaceSearchLimits` / `TextSearchEngine`. Reading them back would make every bound
   self-fulfilling: widening a production default would widen the assertion with it and stay
   green. `testProductionSearchLimitsStillMatchTheFrozenGateCeilings` is the single comparison
   point against production, so a deliberate limit change fails there. Pinned: `4` concurrent
   reads, `100` progress events, `100` reported skipped files, `500` matches per file, `10,000`
   matches per query, `524,288`-byte admission cap, `128` ignore files, `65,536` bytes per ignore
   file, `256` UTF-16 units per query pattern, and `1,024` UTF-16 units of snippet context
   per side.
6. Case policy is covered on both paths. The UI default is `.smart`, which resolves to the
   *insensitive* backend for an all-lowercase or CJK pattern — a different Foundation comparison
   from the `.sensitive` path the original probes measured.
   `testSmartCaseResolvesToInsensitiveMatchingForLowercaseAndCJKPatterns` is the anti-vacuity
   gate: it proves the resolution behaviorally (the same lowercase pattern matches three case
   spellings under `.smart` but one under `.sensitive`), so the two `.smart` budget probes cannot
   silently degenerate into re-measuring the already-budgeted `.sensitive` path.
7. Progress coalescing is compared as a whole sequence, not just its length, monotonicity, and
   final value — those three hold for many wrong sequences, including a stride of 1 truncated at
   100 events and an off-by-one stride. The expected sequence is rebuilt from the documented rule
   (every multiple of `ceil(N / M)` in `1 ... N`, plus a final `N`) rather than read back from
   the stream.
8. Budgets are hard locally and informational on hosted CI (risk R15). Deterministic counts,
   cancellation behavior, and resource ceilings stay hard everywhere, including CI.
9. The two waits in the cancellation probe (window saturation, post-cancel drain) are bounded at
   10 s each and fail the probe on expiry, so a regression cannot stall the test job until the
   CI timeout.

### Fixtures

| Fixture | Shape |
|---|---|
| 2,000-file workspace | 20 directories x 100 files, `.md` and `.mdx`, 2,893,000 bytes total; 500 files contain the query token exactly twice (1,000 matches) |
| Admitted file | exactly 524,288 bytes (the `WorkspaceSearchLimits` admission cap) with the only match in the final line |
| Admission boundary | the same 524,288-byte file plus a 4,194,304-byte sibling (8x the cap). Deliberately not `cap + 1`: with a one-byte-over sibling, a reader that wrongly read the whole file would report the same byte count as one that stopped at the inclusive limit, so the probe could not distinguish them. At 8x the cap a bounded read contributes 524,289 bytes and an unbounded one would contribute 4,194,304, and the probe asserts the former. |
| Dense whole-word (`ascii-suffix`) | 524,288 bytes of ASCII whose every literal hit is rejected by a trailing word character |
| Dense whole-word (`unicode-periodic`) | 524,288 bytes of composed `e`+U+0301 periodic text searched with a 192-UTF-16-unit whole-word pattern; every overlapping candidate is examined and rejected |
| Global match ceiling | 24 files each holding 501 occurrences of the token (one more than the per-file ceiling), so the first 20 files emit 500 matches each and land exactly on the 10,000 per-query ceiling while the remaining four must still be read and accounted |
| Smart case | one small file holding the token in lowercase, title case, and upper case, plus two CJK occurrences; used to prove which matching backend `.smart` resolved to |
| Admitted CJK file | exactly 524,288 bytes of CJK prose with the CJK token in the final line, searched with a CJK pattern under the default `.smart` policy |
| Cancellation | the 2,000-file workspace with a controlled reader that blocks every candidate read |

Two probes carry no wall-clock budget and exist purely as correctness gates:
`testProductionSearchLimitsStillMatchTheFrozenGateCeilings` pins the production ceilings, and
`testGlobalMatchCeilingTruncatesAndDrainsRemainingCandidates` drives the 10,000-match per-query
ceiling for real — it asserts the ceiling is hit exactly (not overshot), that `isGloballyTruncated`
is set, that only the first 20 files emit results in path order, and that all 24 candidates are
still read and counted in the accounting-only phase that follows.

### Measurements and frozen budgets

Each cell is the median of three measured samples within one run; three runs per configuration.

| Metric | Budget | Release medians (3 runs) | Debug medians (3 runs) | Result |
|---|---:|---|---|---|
| Workspace search, 2,000 files | < 3,000 ms | 713.694, 680.838, 680.895 | 1227.007, 1085.104, 1092.670 | Pass |
| Admitted 524,288-byte file | < 150 ms | 7.825, 7.701, 7.630 | 38.837, 38.883, 39.508 | Pass |
| Dense whole-word `ascii-suffix` | < 200 ms | 5.420, 5.665, 5.282 | 48.837, 47.080, 46.710 | Pass |
| Dense whole-word `unicode-periodic` | < 2,500 ms | 611.946, 628.251, 610.962 | 1144.527, 1068.369, 1060.272 | Pass |
| Cancel-to-drain, saturated 4-read window | < 50 ms | 0.185, 0.157, 0.173 | 0.172, 0.161, 0.192 | Pass |

Historical note: at the original 2026-07-25 freeze, a "final-tree" verification run after the
last source edit reported Release workspace search 650.747 ms, admitted file 7.121 ms,
`ascii-suffix` 5.029 ms, `unicode-periodic` 592.165 ms, cancel-to-drain 0.145 ms; Debug
workspace search 1040.001 ms, admitted file 37.661 ms, `ascii-suffix` 45.089 ms,
`unicode-periodic` 1146.458 ms, cancel-to-drain 0.115 ms. **Those values describe the tree as it
was at that freeze, which had 5 probes and no `.smart`, ceiling-pin, or global-ceiling coverage.
They are not a verification of the current tree** — the 2026-07-26 re-measurement above is. They
are retained only to show how the budgets were originally chosen.

Raw in-run samples for the first Release run: workspace search
`[713.694, 681.521, 753.233]`; admitted file `[7.861, 7.825, 7.762]`; `ascii-suffix`
`[5.743, 5.420, 5.403]`; `unicode-periodic` `[611.946, 611.456, 614.041]`; cancellation drain
`[0.222, 0.195, 0.138, 0.091, 0.185]`. Raw in-run samples for the first Debug run: workspace
search `[1137.147, 1227.007, 1292.670]`; admitted file `[39.105, 38.837, 38.790]`; cancellation
drain `[0.213, 0.168, 0.107, 0.238, 0.172]`.

### 2026-07-26 re-measurement after the review-hardening pass

Three Debug and three Release runs of the full 10-probe suite at the review-hardening tip, each
run `test-without-building` against a pre-built product so build work is never inside a sample,
and with nothing else running on the machine. All six runs reported `** TEST EXECUTE SUCCEEDED **`,
10 tests, 0 failures.

These are the numbers **before** the process-level warm-up described below was added. They are
retained because they are the evidence that motivated it, and because the `.smart` budgets were
frozen from them.

| Metric | Budget | Debug medians (3 runs) | Release medians (3 runs) |
|---|---:|---|---|
| Workspace search, 2,000 files (`.sensitive`) | < 3,000 ms | 1868.097, 1386.190, 1432.885 | 884.126, 822.020, 794.526 |
| Workspace search, 2,000 files (`.smart`) | < 4,000 ms | 1538.752, 1356.618, 1297.017 | 761.469, 802.057, 753.301 |
| Admitted 524,288-byte file | < 150 ms | 84.485, 43.255, 54.984 | 10.025, 8.988, 9.115 |
| Admitted 524,288-byte CJK file (`.smart`) | < 150 ms | 34.729, 30.484, 28.548 | 26.973, 26.683, 28.471 |
| Dense whole-word `ascii-suffix` | < 200 ms | 141.794, 50.747, 52.355 | 5.461, 5.956, 5.728 |
| Dense whole-word `unicode-periodic` | < 2,500 ms | 2462.412, 1205.736, 1237.540 | 694.887, 660.877, 743.965 |
| Cancel-to-drain, saturated 4-read window | < 50 ms | 0.193, 0.203, 0.212 | 0.150, 0.173, 0.207 |

The two `.smart` budgets are frozen from these Debug numbers: 4,000 ms is ~2.6x the slowest
`.smart` bulk median, and 150 ms is ~4.3x the slowest CJK median. Notably `.smart` is **not**
slower than `.sensitive` on the bulk workspace — in Release it is consistently a little faster —
so the insensitive backend is not a throughput regression; it was simply unmeasured.

#### Cold-start finding, and the process-level warm-up that resolves it

Debug run 1 above was taken immediately after a build, with cold caches, and the whole suite was
uniformly 1.3x-2.8x slower than runs 2 and 3. `unicode-periodic` produced samples
`[1655.452, 2709.261, 2462.412]` — one sample **above** its 2,500 ms budget, median 2462.412 ms,
1.5% under. That made the budget effectively ~1.0x headroom on a cold run, and `make test` runs
Debug, so the first run after a build was the one most likely to trip it.

The cause is cost paid **per process**, not per probe: dyld work for the first call into
WorkspaceKit and MarkdownCore, Foundation/ICU table initialization on the first Unicode
comparison, first construction of the task-group read pipeline, and CPU frequency ramp from idle.
The existing per-probe warm-up cannot absorb any of it — whichever probe XCTest runs first pays
all of it.

`WorkspaceSearchPerformanceWarmUp` is a one-per-process actor invoked from `setUp()`, outside
every timed region. It runs a bounded search over a small workspace (tens of KiB, not the 512 KiB
cap) that touches each expensive path: candidate planning, anchored reads, UTF-8 decoding, both
case backends, composed whole-word rejection, snippet construction, and stream delivery.

This changes the harness, not the product: process start-up is not search cost, and the budgets
describe steady-state search. The trade-off is explicit — the gate no longer sees process
start-up regressions, which it only ever observed by accident through whichever probe ran first.

Measured effect on the cold first Debug run after a build, same machine and conditions:

| Metric | Budget | Cold run 1, before | Cold run 1, after |
|---|---:|---:|---:|
| Workspace search, 2,000 files (`.sensitive`) | < 3,000 ms | 1868.097 | 1198.152 |
| Admitted 524,288-byte file | < 150 ms | 84.485 | 40.826 |
| Admitted 524,288-byte CJK file (`.smart`) | < 150 ms | 34.729 | 26.524 |
| Dense whole-word `ascii-suffix` | < 200 ms | 141.794 | 48.508 |
| Dense whole-word `unicode-periodic` | < 2,500 ms | **2462.412** | **1149.402** |
| Cancel-to-drain | < 50 ms | 0.193 | 0.197 |

`unicode-periodic`'s worst individual cold sample went from 2709.261 ms (over budget) to
1177.059 ms. Run-to-run spread also collapsed: its three medians were 2462.412 / 1205.736 /
1237.540 before and 1149.402 / 1112.387 / 1102.974 after.

#### Post-warm-up measurement (current tip)

Three Debug and three Release runs, `test-without-building`, quiet machine. All six reported
`** TEST EXECUTE SUCCEEDED **`, 10 tests, 0 failures.

| Metric | Budget | Debug medians (3 runs) | Release medians (3 runs) |
|---|---:|---|---|
| Workspace search, 2,000 files (`.sensitive`) | < 3,000 ms | 1198.152, 1160.181, 1237.518 | 718.984, 758.269, 645.777 |
| Workspace search, 2,000 files (`.smart`) | < 4,000 ms | 1174.411, 1161.879, 1201.410 | 874.124, 709.593, 647.714 |
| Admitted 524,288-byte file | < 150 ms | 40.826, 42.260, 41.757 | 8.421, 7.982, 10.361 |
| Admitted 524,288-byte CJK file (`.smart`) | < 150 ms | 26.524, 32.077, 27.830 | 28.159, 25.740, 27.081 |
| Dense whole-word `ascii-suffix` | < 200 ms | 48.508, 61.164, 49.227 | 6.351, 5.556, 5.578 |
| Dense whole-word `unicode-periodic` | < 2,500 ms | 1149.402, 1112.387, 1102.974 | 665.317, 725.112, 648.667 |
| Cancel-to-drain, saturated 4-read window | < 50 ms | 0.197, 0.195, 0.202 | 0.234, 0.170, 0.165 |

### Post-#94 Release re-verification

Three Release runs at merge commit `9b89bce`, after `main` at `58740ac` (PR #94) was merged in, so
the documented Release command runs with **no** `SWIFT_ACTIVE_COMPILATION_CONDITIONS` override. All
three reported `** TEST SUCCEEDED **`, 7 tests, 0 failures. The first run built from a cleaned
`plainsong-ws4b-release` DerivedData.

| Metric | Budget | Post-#94 Release medians (3 runs) | Pre-#94 Release medians (3 runs) | Result |
|---|---:|---|---|---|
| Workspace search, 2,000 files | < 3,000 ms | 697.214, 696.860, 766.784 | 713.694, 680.838, 680.895 | Pass |
| Admitted 524,288-byte file | < 150 ms | 8.071, 8.443, 11.466 | 7.825, 7.701, 7.630 | Pass |
| Dense whole-word `ascii-suffix` | < 200 ms | 5.542, 5.524, 5.513 | 5.420, 5.665, 5.282 | Pass |
| Dense whole-word `unicode-periodic` | < 2,500 ms | 629.910, 630.545, 708.431 | 611.946, 628.251, 610.962 | Pass |
| Cancel-to-drain, saturated 4-read window | < 50 ms | 0.209, 0.178, 0.217 | 0.185, 0.157, 0.173 | Pass |

Every metric stays in the same range as the pre-#94 runs, with the third run uniformly a little
slower (unrelated load on the machine, visible across all five metrics at once rather than in any
single path). No budget was changed as a result of this re-verification.

### First hosted CI observation

GitHub Actions `build-and-test` on `macos-15` for PR #93 commit
`d47404392cc64bcc0480e828aa79e509b6fe7f2c` produced these medians: workspace search
1239.690 ms (samples `[1126.512, 1239.690, 1386.824]`), admitted file 43.802 ms,
`ascii-suffix` 46.440 ms, `unicode-periodic` 985.311 ms, cancel-to-drain 0.137 ms. Every value
was under budget, so no R15 informational line was printed on that run. This is recorded as a
hosted datapoint only; per R15 the local values above remain the acceptance evidence, and these
budgets stay informational on CI regardless.

### Budget selection

Budgets are frozen against the **Debug** medians because `make test` runs the Debug
configuration, and Debug is roughly 2x slower than Release on these paths. No budget was chosen
to rescue a failing run: the first Debug run of the `unicode-periodic` shape exceeded an initial
750 ms guess, and the response was to measure Release, confirm the cost is the documented worst
case behind the 512 KiB admission cap, and freeze an evidence-based budget instead.

Headroom over the measured Debug median, from the post-warm-up runs (slowest of the three
medians per metric, so this is the worst case across a cold first run and two warm ones):

| Metric | Budget | Slowest Debug median | Headroom |
|---|---:|---:|---:|
| Workspace search, 2,000 files (`.sensitive`) | 3,000 ms | 1237.518 ms | 2.4x |
| Workspace search, 2,000 files (`.smart`) | 4,000 ms | 1201.410 ms | 3.3x |
| Admitted 524,288-byte file | 150 ms | 42.260 ms | 3.5x |
| Admitted 524,288-byte CJK file (`.smart`) | 150 ms | 32.077 ms | 4.7x |
| Dense whole-word `ascii-suffix` | 200 ms | 61.164 ms | 3.3x |
| Dense whole-word `unicode-periodic` | 2,500 ms | 1149.402 ms | 2.2x |
| Cancel-to-drain | 50 ms | 0.202 ms | 248x |

History worth keeping: an earlier revision claimed a uniform 2.4x-3.8x headroom, which was true
only of warm runs. Measured against cold first runs, three of the seven metrics fell under 2x and
`unicode-periodic` sat at 1.0x — effectively at parity with its budget. The process-level warm-up
above is what restored the claim, rather than any budget being widened; every budget in this
table is unchanged from its original freeze.

### Notes

- The `unicode-periodic` result is production-shaped confirmation of the
  `docs/workspace-search-plan.md` §2.3 admission cap: 612 ms in Release at exactly 512 KiB. A
  1 MiB cap would put a single adversarial file over one second in Release, which is why the cap
  was not raised.
- Memory boundedness is asserted structurally rather than with a resident-memory threshold: the
  four-read window (concurrent, buffered, and outstanding), the finite event bound
  (`results + progress + terminal`, exactly 601 events for the 2,000-file fixture), the
  per-file/per-query match caps, the bounded snippet size, and the exact admitted byte count are
  all hard assertions. No RSS assertion was added, because RSS on this path is dominated by
  allocator and page-cache behavior that is not stable enough for a gate.
- The cancellation probe proves that after cancelling the consuming Task, all four blocked reads
  are released, no further read starts, and no `completed` or `failed` terminal event is emitted.

## Typing Latency

- Fixture: `Fixtures/large-1mb.md`
- Procedure:
  1. Ran `make test`, which includes `PerformanceTests.testTypingLatencyStaysUnderFrameBudget`.
  2. The test reuses `EditorPerformanceProbe.measureTypingHotPath` against the committed
     `Fixtures/large-1mb.md` and covers Markdown plain typing, Markdown newline, Markdown
     auto-pair trigger, MDX plain typing, and MDX JSX trigger.
  3. Captured `TypingLatency` signposts in the Xcode result bundle.
- Measured value: maximum observed sample was 0.254 ms (`mdx jsx trigger`; 50 iterations).
  Other samples: Markdown plain 0.014 ms, Markdown newline 0.108 ms, Markdown pair
  0.194 ms, MDX plain 0.001 ms.
- Result: Pass.
- Notes: Existing EditorKit hot-path frame-budget package tests also passed in the
  same `make test` run.

## Highlight Update

- Fixture: `Fixtures/large-1mb.md` plus an MDX fixture with multiline JSX.
- Procedure:
  1. Ran `PerformanceTests.testVisibleRangeHighlightUpdateAfterEditStaysUnderBudgetForLargeMarkdownAndMDX`.
  2. The test edits the committed 1 MB Markdown fixture and an MDX wrapper around that
     fixture, then highlights a 6 KB viewport-like visible range around the edit.
  3. The highlighter expands the request to whole lines and lightweight frontmatter/fence
     context, parses inline/TSX markup inside that visible request, and applies attributes
     only to the highlighted range.
  4. The measurement includes visible-range tokenization plus in-place attribute apply,
     and excludes preview debounce/render work.
- Measured value: Markdown max 17.918 ms, samples `[17.918, 15.860, 16.691]`;
  MDX max 22.670 ms, samples `[21.703, 21.189, 22.670]`.
- Result: Pass.
- Notes: This pass is based on visible-range-first plumbing and instrumentation, not on
  the historical 250 KB full-document inline parsing cutoff. The partial apply preserves
  selection and scroll position, disables undo registration for style-only edits, and
  skips apply while CJK IME marked text exists.

## Preview Render

- Fixture: `Fixtures/perf-100kb.md`
- Procedure:
  1. Ran `make test`, which includes `PerformanceTests.testPreviewRenderFor100KBMarkdownAndMDXStaysUnderBudget`.
  2. Warmed the preview bridge and MDX parser path, primed the live WebView with the 91,486-byte
     deterministic fixture, then ran three unmeasured settling updates to keep one-time WebKit,
     highlight, and morphdom startup work out of the settled post-debounce budget.
  3. Measured three settled large-document updates from Swift render request to JS
     `renderComplete`.
  4. Gated the median of three settled updates for `.md` and `.mdx` in local runs; raw samples are printed by the test.
  5. Captured `PreviewRenderMarkdown100KB` and `PreviewRenderMDX100KB` signposts in the Xcode result bundle.
- Measured value: Markdown median 46.631 ms, samples `[63.104, 45.942, 46.631]`.
  MDX median 14.556 ms, samples `[14.981, 14.556, 14.355]`.
- Informational cold/prime values: preview bridge warmup 476.351 ms, MDX warmup
  5.672 ms, first 100 KB Markdown prime 86.406 ms, first 100 KB MDX prime 51.054 ms.
  Unmeasured settling renders were Markdown `[79.001, 56.417, 54.737]` and MDX
  `[38.429, 14.946, 14.787]`.
- Result: Pass.
- Notes: The preview path now preserves unchanged highlighted code nodes through morphdom so
  settled large-document updates do not re-highlight unchanged fences. The budget measurement
  intentionally excludes the 150 ms debounce and records settled update render work after
  debounce. The first 100 KB Markdown prime is recorded above as informational, not claimed
  as the passing update measurement. GitHub Actions `macos-15` WebKit runs for PR #20/#21
  observed Markdown medians above the local budget (107.397 ms and 148.847 ms) while MDX
  stayed under budget (44.673 ms and 70.334 ms); those hosted-runner values are recorded
  as CI informational only and are not M5 passing evidence.

## File Open

- Fixture: `Fixtures/perf-500kb.md`
- Procedure:
  1. Ran `make test`, which includes `PerformanceTests.testOpening500KBMarkdownToEditorFirstPaintStaysUnderBudget`.
  2. Warmed the editor surface with a tiny document so one-time AppKit/editor framework
     initialization does not dominate the document-open budget.
  3. Loaded `Fixtures/perf-500kb.md` through `MarkdownFileStore`, created a `DocumentSession`,
     and forced an EditorKit `MarkdownSTTextView` layout/display pass as the first-paint proxy.
  4. Captured `FileOpen500KBFirstPaint` signposts in the Xcode result bundle.
- Measured value: 33.765 ms.
- Result: Pass.
- Notes: This is an automated load + editor paint proxy, not a full Finder/Open Panel UI path.

## Memory

- Scenario: 8 warm document sessions and 2 live preview webviews in a deterministic
  test-only harness.
- Procedure:
  1. Create exactly 8 warm `DocumentSession`s from `Fixtures/perf-500kb.md`.
  2. Attach a first `PreviewController`/`WKWebView` to an offscreen 1280 x 720 AppKit
     surface, wait for bridge readiness, and render/settle `Fixtures/perf-100kb.md`.
  3. Record the single-webview RSS as informational only: 149.3 MB host RSS.
  4. Attach a second live `PreviewController`/`WKWebView` to the same surface, wait for
     bridge readiness, and render/settle an MDX-wrapped `Fixtures/perf-100kb.md`.
  5. Re-check both previews contain their final settled markers, wait one short display
     turn, then record resident memory.
- Measured value: 149.8 MB host RSS with 8 warm `DocumentSession`s and 2 settled live
  `PreviewController` WebViews.
- Result: Pass.
- Notes: The Section 12 M5 memory gate is app host-process RSS. The automated gate asserts
  the same deterministic host-process RSS helper used by PR #15, now with two live previews.
  The test also printed a diagnostic WebKit helper delta of 498.6 MB across 2 OS-managed
  helper processes, for a 648.3 MB aggregate; this is not asserted because WebKit helper
  reuse and process-pool ownership are not stable enough for CI on this local machine. The
  single-webview 149.3 MB value remains informational only and is not used to satisfy the
  Section 12 memory gate.

## Release Configuration Verification (P5)

| Field | Value |
|---|---|
| Date | 2026-07-05 |
| Commit | `main` after PR #59 |
| macOS / Xcode | Build machine OS 26A5368g; Xcode beta 27A5194q (DTXcode 2700, SDK macosx27.0) |
| Machine | Owner's Apple Silicon MacBook Pro (arm64) |
| Build configuration | `Release` + `ENABLE_TESTABILITY=YES` override; `-only-testing:PerformanceTests` |
| Command | `xcodebuild -project Plainsong.xcodeproj -scheme Plainsong -configuration Release -derivedDataPath ~/Library/Developer/Xcode/DerivedData/plainsong-perf-release ENABLE_TESTABILITY=YES -only-testing:PerformanceTests test` |
| Result | `** TEST SUCCEEDED **`; all budgets pass |
| Notes | This closes the final P5 item in `docs/release-engineering-plan.md`. Pitfall recorded: pointing `-derivedDataPath` inside `~/Documents` makes the spawned xctest agent unable to read the built bundle (macOS TCC privacy protection on Documents), which surfaces as "The bundle couldn't be loaded because its executable couldn't be located" even though the binary exists — keep test DerivedData under `~/Library/Developer`. Second pitfall recorded (fixed 2026-07-25): `xcodebuild` builds *every* test target even under `-only-testing`, so any `AppTests` reference to an App symbol behind `#if DEBUG` breaks this Release command with `cannot find … in scope`. Keep such tests guarded — `#if !DEBUG` + `XCTSkip` for the test itself, `#if DEBUG` around Debug-only private helpers — rather than passing a `SWIFT_ACTIVE_COMPILATION_CONDITIONS` override, which would make Release evidence depend on a Debug build setting. |

| Metric | Budget | Release measured | Result |
|---|---:|---:|---|
| Typing latency | < 16 ms | 0.525 ms max (markdown pair; other samples ≤ 0.091 ms) | Pass |
| Highlight update visible range | < 50 ms | Markdown 8.517 ms max; MDX 10.050 ms max | Pass |
| Preview render, 100 KB document | < 100 ms after debounce | Markdown 46.680 ms median; MDX 14.721 ms median | Pass |
| File open, 500 KB Markdown | < 300 ms to first paint | 31.977 ms | Pass |
| Memory with 8 warm sessions + 2 webviews | < 400 MB host RSS | 149.3 MB host RSS (WebKit helpers 511.6 MB across 2, aggregate 660.9 MB diagnostic only) | Pass |

## Follow-up Actions

- [x] [#14](https://github.com/w3d-su/plainsong/issues/14): land and instrument visible-range highlighting before claiming the
  < 50 ms highlight-update budget; current evidence uses visible-range-first parsing/apply, not the historical
  250 KB full-document inline parsing cutoff.
- [x] [#13](https://github.com/w3d-su/plainsong/issues/13): add a deterministic two-live-webview memory harness under the
  host-process RSS policy. Issue #13 is closed with the scope note above.
