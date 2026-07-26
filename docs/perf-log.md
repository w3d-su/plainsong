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

This section is the complete record for the WS4B gate. It is rewritten rather than amended on
each revision, so it carries one set of current numbers instead of a chain of corrections.
Superseded values are not retained except where a finding is explicitly about how they changed.

| Field | Value |
|---|---|
| Date | 2026-07-26 |
| Branch | `phase3-search-ws4b-performance-gates`, originally branched from `main` at `fe953db`, with `main` at `58740ac` (PR #94) merged in at `9b89bce` |
| Measured commit | `a09cafb91f2194b04d1777bcb28a9259933101c1` — the commit holding the measured source. The commit stamping this row is its direct child and differs only in this line; no Swift source changed between them. |
| macOS | Darwin 27.0.0 |
| Machine | Apple Silicon, arm64, 16 GB RAM |
| Probe count | 14 WS4B tests, part of 23 in the `PerformanceTests` target |
| Source files | 11: `WorkspaceSearchPerformanceTests` (class, frozen constants, ceiling pins, throughput probes), `…SmartCase…`, `…Ceiling…`, `…Cancellation…`, `…ReadBounds…` (probes), `…PerformanceFixtures`, `…PerformanceIgnoreFixtures`, `…PerformanceAssertions`, `…PerformanceSupport`, `…PerformanceWarmUp`, `…PerformanceBlockingReader`. Split from one 1,258-line file to stay near the ~400-line guidance in agent.md §17.10 |

### Reproduction

Build once, then run. Timing runs use `test-without-building` so no build work can land inside a
sample; the `build-for-testing` step is separate and unmeasured. `ENABLE_TESTABILITY=YES` is
required in Release because `WorkspaceSearchReadBoundsPerformanceTests` uses
`@testable import WorkspaceKit` to install the reader's `readChunk` observation hook.

Debug (what `make test` exercises):

```
rm -rf ~/Library/Developer/Xcode/DerivedData/plainsong-ws4b-debug
xcodebuild -project Plainsong.xcodeproj -scheme Plainsong -configuration Debug \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/plainsong-ws4b-debug \
  -only-testing:PerformanceTests build-for-testing
xcodebuild -project Plainsong.xcodeproj -scheme Plainsong -configuration Debug \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/plainsong-ws4b-debug \
  -only-testing:PerformanceTests/WorkspaceSearchPerformanceTests test-without-building
```

Release:

```
rm -rf ~/Library/Developer/Xcode/DerivedData/plainsong-ws4b-release
xcodebuild -project Plainsong.xcodeproj -scheme Plainsong -configuration Release \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/plainsong-ws4b-release \
  ENABLE_TESTABILITY=YES -only-testing:PerformanceTests build-for-testing
xcodebuild -project Plainsong.xcodeproj -scheme Plainsong -configuration Release \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/plainsong-ws4b-release \
  ENABLE_TESTABILITY=YES \
  -only-testing:PerformanceTests/WorkspaceSearchPerformanceTests test-without-building
```

Both run at this branch tip with no build-setting override beyond `ENABLE_TESTABILITY`. Before
PR #94 was merged the Release command exited 65 here, because `AppTests` referenced App probes
that exist only under `#if DEBUG` and `xcodebuild` builds every test target even under
`-only-testing`; merging `main` at `58740ac` removed that. Keep test DerivedData under
`~/Library/Developer` — pointing it inside `~/Documents` makes the spawned xctest agent unable to
read the built bundle under macOS TCC.

### Procedure

1. Every probe that issues a search drives the real `WorkspaceSearchService` over a real on-disk
   workspace. (`testProductionSearchLimitsStillMatchTheFrozenGateCeilings` performs no search; it
   only compares pinned constants.) Those probes use the production
   `WorkspaceSearchDiskFileReader`, so the measurement includes
   candidate planning, ignore-policy probes, anchored no-follow reads, UTF-8 decoding,
   MarkdownCore matching, snippet construction, and stream delivery. The cancellation probe is
   the one deliberate exception: it substitutes a controlled reader that blocks every candidate
   read, because a deterministic cancel-to-drain measurement needs a saturated read window that
   cannot finish on its own.
2. Fixture creation and `WorkspaceDirectoryScanner.snapshotCapture` run before timing starts and
   are never inside a measured region.
3. Each timed search probe runs one unmeasured warm-up request, then three measured requests. The
   warm-up is asserted with the same deterministic predicates as the measured samples, so a
   warm-up that searched nothing cannot make later samples cheap. The cancellation probe has no
   warm-up; it repeats five independent cancellations and reports their median.
4. A separate one-per-process warm-up (`WorkspaceSearchPerformanceWarmUp`, invoked from
   `setUp()`) runs a bounded search before any probe executes. Callers await a shared task rather
   than a flag, so a second caller cannot race ahead of an in-flight warm-up, and the warm-up
   validates its own stream — one completion terminal, no failure terminal, expected searched and
   matching file counts — so a warm-up that silently failed cannot be recorded as done. A failure
   is not cached, so it surfaces instead of leaving every later probe measuring a cold process.
5. Every run that reaches completion with at least one surviving candidate — measured sample,
   warm-up, and controls alike — goes through `assertSharedStreamInvariants`: exact event count,
   the full progress sequence, read-window ceilings, the skipped-detail cap, and completion as
   the final event. The one exception is the under-ceiling ignore control, where the ignore rule
   removes the only candidate so the progress model does not apply; that probe asserts terminal
   correctness directly instead (exactly one terminal, no failure, completion last).
6. Resource ceilings are pinned as literals in the test file, not read back from
   `WorkspaceSearchLimits` / `TextSearchEngine`. Reading them back would make every bound
   self-fulfilling. `testProductionSearchLimitsStillMatchTheFrozenGateCeilings` is the single
   comparison point against production. Pinned: `4` concurrent reads, `100` progress events,
   `100` reported skipped files, `500` matches per file, `10,000` matches per query,
   `524,288`-byte admission cap, `128` ignore files, `65,536` bytes per ignore file, `256` UTF-16
   units per query pattern, `1,024` UTF-16 units of snippet context per side.
7. Budgets are hard locally and informational on hosted CI (risk R15). Deterministic counts,
   cancellation behavior, and resource ceilings stay hard everywhere, including CI.
8. The cancellation probe's two waits are bounded at 10 s each and fail the probe on expiry, so a
   regression cannot stall the test job to the CI timeout.

### What each probe can actually falsify

Every probe below was checked against the question "what break would this still pass?" — the
third and fourth review passes removed four cases where the answer was "the one it exists to
catch": derived resource ceilings, an unreachable global match cap, a `cap + 1` oversized fixture,
and read bounds asserted from chunk counts rather than syscall byte counts.

| Probe | Would fail if… |
|---|---|
| 2,000-file workspace (`.sensitive` and `.smart`) | ordered results, per-file ranges/lines, summary accounting, event count, or read-window ceilings regress |
| `testSmartCaseResolvesToInsensitiveMatchingForLowercaseAndCJKPatterns` | `.smart` stopped resolving to the insensitive backend. One lowercase pattern matches three case spellings under `.smart` but one under `.sensitive`; a CJK pattern with a lowercase Latin suffix matches an upper-case occurrence under `.smart` and nothing under `.sensitive` |
| Admitted 512 KiB file, and the CJK file under `.smart` | the match near EOF is missed, or byte accounting drifts. The CJK probe carries its own `.sensitive` control that must match nothing, so it cannot degenerate into re-measuring the sensitive path |
| `testOversizedFileIsReadOnlyToTheInclusiveLimit` | the reader read past `inclusiveLimit(cap)`. Asserted on `readChunk` events from the production reader, which carry the bytes **requested of** and **returned by** each `read(2)`: 9 chunks totalling exactly 524,289 requested bytes with a final one-byte request. Chunk counts alone would not suffice — a loop that asked for a full 64 KiB buffer on the last read and truncated afterwards produces the same nine indices |
| `testOversizedIgnoreFileIsBoundedAndItsRulesAreRejected` plus its under-ceiling control | the 64 KiB ignore ceiling stopped rejecting over-size ignore files, or their reads stopped being bounded — asserted as 2 chunks totalling exactly 65,537 requested bytes, so two full-buffer reads (131,072 bytes) would fail. The control proves the same rule *is* honored under the ceiling, so "nothing was suppressed" cannot pass by the rule never working |
| `testProgressCoalescingUsesCeilingStrideOnNonDivisibleCandidateCounts` | the stride became `floor` instead of `ceil`, or the final `N / N` event was dropped. Uses 250 candidates: every other fixture has `N ≤ 100` or `N` divisible by 100, where both mistakes are invisible |
| `testGlobalMatchCeilingTruncatesAndDrainsRemainingCandidates` | the 10,000-match ceiling were overshot, `isGloballyTruncated` unset, results emitted past the ceiling, or remaining candidates not drained for accounting |
| `testProductionSearchLimitsStillMatchTheFrozenGateCeilings` | any pinned production ceiling moved |
| Cancellation | a read were left running, another started, or a terminal event emitted after cancel |

### Fixtures

| Fixture | Shape |
|---|---|
| 2,000-file workspace | 20 directories x 100 files, `.md` and `.mdx`, 2,893,000 bytes total; 500 files contain the query token exactly twice (1,000 matches) |
| Admitted file | exactly 524,288 bytes (the admission cap) with the only match in the final line |
| Admission boundary | the same 524,288-byte file plus a 4,194,304-byte sibling, 8x the cap. Deliberately not `cap + 1`: at one byte over, a bounded read and a read-everything-then-truncate reader report identical byte counts |
| Admitted CJK file | exactly 524,288 bytes of CJK prose whose final line holds `平明歌X`, searched with the lowercase pattern `平明歌x` |
| Smart case | one file holding the token in lowercase, title case and upper case, two CJK occurrences, and one CJK+upper-case-Latin occurrence |
| Oversized ignore | one matching file plus a 262,144-byte `.gitignore` naming it, with the rule on the first line |
| Under-ceiling ignore | the same file and rule in a `.gitignore` of a few dozen bytes |
| Progress stride | 250 files, above the 100-event cap and not divisible by it |
| Global match ceiling | 24 files of 501 occurrences each, so the first 20 emit 500 matches apiece and land exactly on the 10,000 ceiling |
| Dense whole-word (`ascii-suffix`) | 524,288 bytes of ASCII whose every literal hit is rejected by a trailing word character |
| Dense whole-word (`unicode-periodic`) | 524,288 bytes of composed `e`+U+0301 periodic text searched with a 192-UTF-16-unit whole-word pattern |
| Cancellation | the 2,000-file workspace with a controlled reader that blocks every candidate read |

### Measurements

Three Debug and three Release runs at the measured commit, quiet machine, each `test-without-building`
against the pre-built product. All six reported `** TEST EXECUTE SUCCEEDED **`, 14 tests, 0 failures.
The full `PerformanceTests` target was also run in Release: 23 tests, 0 failures.

| Metric | Budget | Debug medians (3 runs) | Release medians (3 runs) | Headroom |
|---|---:|---|---|---:|
| Workspace search, 2,000 files (`.sensitive`) | < 3,000 ms | 1075.583, 1034.997, 1060.381 | 854.278, 808.488, 868.376 | 2.8x |
| Workspace search, 2,000 files (`.smart`) | < 4,000 ms | 1097.697, 1042.528, 1119.895 | 1118.649, 901.823, 752.182 | 3.6x |
| Admitted 524,288-byte file | < 150 ms | 37.794, 37.784, 37.991 | 8.979, 9.168, 10.970 | 3.9x |
| Admitted 524,288-byte CJK file (`.smart`) | < 150 ms | 24.892, 24.559, 24.547 | 27.948, 30.141, 29.815 | 6.0x |
| Dense whole-word `ascii-suffix` | < 200 ms | 45.242, 45.500, 45.635 | 5.870, 6.044, 6.061 | 4.4x |
| Dense whole-word `unicode-periodic` | < 2,500 ms | 1027.955, 1025.876, 1021.251 | 660.601, 673.219, 702.148 | 2.4x |
| Cancel-to-drain, saturated 4-read window | < 50 ms | 0.162, 0.174, 0.141 | 0.210, 0.187, 0.186 | 287x |

Headroom is budget divided by the *slowest* of the three Debug medians, so it is the worst case
across a cold first run and two warm ones.

### Budget selection

Budgets are frozen against Debug medians because `make test` runs Debug, which is roughly 2x
slower than Release on these paths. No budget was chosen to rescue a failing run: the first Debug
run of the `unicode-periodic` shape exceeded an initial 750 ms guess, and the response was to
measure Release, confirm the cost is the documented worst case behind the 512 KiB admission cap,
and freeze an evidence-based budget instead. The `.smart` budgets were frozen the same way, from
the Debug medians measured when those probes were added.

`.smart` is **not** meaningfully slower than `.sensitive` on the bulk workspace — the two are
within run-to-run noise of each other in Debug, and each has been the faster of the two across
different Release runs. The gap this pass closed was missing coverage of the default path, not a
throughput regression.

Headroom is budget divided by the *slowest* of the three Debug medians, and is not uniform: it
ranges from 2.4x (`unicode-periodic`) to 6.0x (CJK). An earlier revision of this document claimed
a uniform 2.4x-3.8x; that was true only of warm runs before the process warm-up existed, and is
replaced by the per-metric column in the measurement table above.

### Cold-start finding and the process warm-up

Before the process-level warm-up existed, the first Debug run after a build was uniformly
1.3x-2.8x slower than the runs after it, and `unicode-periodic` produced samples
`[1655.452, 2709.261, 2462.412]` — one sample **above** its 2,500 ms budget, median 2462.412 ms,
1.5% under. That made the budget effectively ~1.0x headroom cold, and `make test` runs Debug.

The cause is cost paid per *process*, not per probe: dyld work for the first call into
WorkspaceKit and MarkdownCore, Foundation/ICU table initialization on the first Unicode
comparison, first construction of the task-group read pipeline, and CPU frequency ramp from idle.
The per-probe warm-up cannot absorb any of it — whichever probe XCTest runs first pays all of it.

`WorkspaceSearchPerformanceWarmUp` runs one bounded search over a small workspace (tens of KiB)
before any probe, touching each expensive path. Cold first Debug run after a build, same machine:
`unicode-periodic` 2462.412 → 1149.402 ms, worst sample 2709.261 → 1177.059 ms; bulk workspace
1868.097 → 1198.152 ms; `ascii-suffix` 141.794 → 48.508 ms; admitted file 84.485 → 40.826 ms.

This moves the harness, not the product: process start-up is not search cost, and the budgets
describe steady-state search. The explicit trade-off is that the gate no longer observes process
start-up regressions, which it only ever caught by accident through whichever probe ran first.
**No budget was changed** — every number in the budget table is its original frozen value.

### First hosted CI observation

GitHub Actions `build-and-test` on `macos-15` for PR #93 commit
`d47404392cc64bcc0480e828aa79e509b6fe7f2c` produced these medians: workspace search
1239.690 ms (samples `[1126.512, 1239.690, 1386.824]`), admitted file 43.802 ms,
`ascii-suffix` 46.440 ms, `unicode-periodic` 985.311 ms, cancel-to-drain 0.137 ms. Every value
was under budget, so no R15 informational line was printed on that run. This predates the
`.smart`, ceiling, read-bounds, and progress-stride probes and the process warm-up; it is
recorded as a hosted datapoint only. Per R15 the local values above remain the acceptance
evidence, and these budgets stay informational on CI regardless.

### Notes

- The `unicode-periodic` result is production-shaped confirmation of the
  `docs/workspace-search-plan.md` §2.3 admission cap: ~611 ms in Release at exactly 512 KiB. A
  1 MiB cap would put a single adversarial file over one second in Release, which is why the cap
  was not raised.
- Memory boundedness is asserted structurally rather than with a resident-memory threshold: the
  four-read window (concurrent, buffered, and outstanding), the finite event bound, the
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
