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
5. Every run that reaches completion goes through `assertSharedStreamInvariants`: exact event
   count, the full progress sequence, read-window ceilings, and completion as the final event.
   That includes the under-ceiling ignore control — an ignored entry is still a plan item and
   still counts toward `candidateFileCount`, so production emits its `1 / 1` progress event and
   the helper applies. The only component with a separate validator is the process warm-up, which
   runs before XCTest assertions are meaningful and throws typed errors instead: exactly one
   terminal event, no failure terminal, no validation failure, and nothing emitted after the
   terminal. The cancellation probe is checked differently again, by consumer-observed silence.

   The helper also carries a `skippedFiles.count <= 100` bound, but that is a shape check rather
   than evidence: no fixture here produces more than one skipped file, so the bound is never
   approached. Cap enforcement is proven in WorkspaceKit by
   `WorkspaceSearchResourceContractTests.testSlowConsumerReceivesBoundedLosslessResultsDetailsProgressAndTerminal`
   (600 skips against a detail limit of 7, asserting both the retained prefix and
   `omittedSkippedFileCount`). WS4B's contribution is pinning that production's default is 100.
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
eight review passes removed cases where the answer was "the one it exists to catch": resource
ceilings read back from the production limits they checked and a global match cap asserted only by
an unreachable inequality (first pass); a `cap + 1` oversized fixture that could not distinguish a
bounded read from a truncating one (second); read bounds asserted from `Data.count`, an ignore
ceiling with no behavior attached, and progress coalescing exercised only where `floor` and `ceil`
agree (third); chunk counts that still could not catch a final full-buffer read (fourth);
CJK-cased controls that still bypassed the shared invariants, stale source budget comments, and
incomplete or numerically false Decision Log records (`a777dc4`, fifth); zero-result controls that
could not tell "searched and found nothing" from "never looked" (sixth); a cancellation probe
checking only some event kinds, a warm-up accepting validation failures, and an ignore control
that skipped the progress invariant outright (seventh); and a cancellation assertion whose scope
was overstated, plus a vacuous skipped-detail bound (eighth).

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
| Cancellation | any blocked read was left running, another read started, or the consumer observed any event |

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
  `docs/workspace-search-plan.md` §2.3 admission cap: 660.601-702.148 ms in Release at exactly
  512 KiB across the three authoritative runs. A
  1 MiB cap would put a single adversarial file over one second in Release, which is why the cap
  was not raised.
- Memory boundedness is asserted structurally rather than with a resident-memory threshold: the
  four-read window (concurrent, buffered, and outstanding), the finite event bound, the
  per-file/per-query match caps, the bounded snippet size, and the exact admitted byte count are
  all hard assertions. No RSS assertion was added, because RSS on this path is dominated by
  allocator and page-cache behavior that is not stable enough for a gate.
- The cancellation probe proves that after cancelling the consuming Task, all four blocked reads
  are released, no further read starts, and the consumer observes no events at all. Scope: that
  last part is what the *consumer* saw. Cancelling the consuming Task also terminates the
  `AsyncStream` continuation, so a terminal the producer wrongly yielded afterwards would be
  discarded before reaching the collected events. Proving the producer never attempts a
  post-cancellation terminal would need a yield-observation seam or a direct pipeline test, and
  this gate does not claim it.


## Phase 3 F2 In-Document Find Performance Gate

This is the complete authoritative baseline for the F2 query-completion and production-hosted
state-update receipt proxies. All six retained runs measured the exact clean source at
`c871ddf5c66c17f03fd9456b53f79411f9b2e979`. That commit contains the warning-phase checker,
exact-source build/run wrappers, and resolved-package-input seal used by every retained run.

| Field | Value |
|---|---|
| Date | 2026-07-30 (Asia/Taipei) |
| Branch | `codex/editor-find-f2-performance-probe`; `origin/main` at `250e91e16a1fd5339096ec96b84fcfe6e9790c4c` is an ancestor |
| Measured source commit | `c871ddf5c66c17f03fd9456b53f79411f9b2e979` |
| macOS | macOS 27.0 (26A5388g) |
| Xcode | Xcode 27.0 (27A5194q) |
| XcodeGen | 2.45.4; binary SHA-256 `3b483413a801394b00adb2fabf3c06ff8f800c73c8698e1f9a9d8a95d73939ef` |
| Machine | MacBook Pro (MacBookPro18,3), Apple M1 Pro (8 cores), arm64, 16 GB RAM |
| Fixture | `Fixtures/large-1mb.md`: 1,048,962 bytes; SHA-256 `d174f48ea6175db568abe44e5b71e82ee92f1cf9c0ed081d8f8308cc1961d247` |
| Tests | `EditorFindPerformanceTests.testLargeFixtureFindQueryCompletionForZeroSparseAndDenseCases`; `...testProductionWorkspaceFindOpenEditAdmissionAndStateReceiptStayWithinMeasuredBudgets` |
| Result | Pass — three Debug and three Release local-hard runs, two tests per run, zero failures; warning exception passed the raw-log phase checker in all six runs. |

The exact retained run prefixes are:

```text
/private/tmp/plainsong-f2-c871ddf-debug-run1
/private/tmp/plainsong-f2-c871ddf-debug-run2
/private/tmp/plainsong-f2-c871ddf-debug-run3
/private/tmp/plainsong-f2-c871ddf-release-run1
/private/tmp/plainsong-f2-c871ddf-release-run2
/private/tmp/plainsong-f2-c871ddf-release-run3
```

Each prefix has a raw `.log`, immutable raw `.xcresult`, `.log.sha256`,
`.warning-check.txt`, `.warning-check.txt.sha256`, `.evidence-manifest.txt`, immutable
`.inspection.xcresult` copy, and immutable `.products` snapshot. The run wrapper refuses to
overwrite any of them. It streams the raw console to the log without hiding `xcodebuild` failure,
hashes and freezes the log/result before inspection, checks the warning phase against the raw log,
checks the coalesced issue against the inspection copy, re-verifies all source/build hashes, and
only then writes `status=pass` to the evidence manifest.

| Run | Raw log SHA-256 | Raw `.xcresult` SHA-256 | Warning-check SHA-256 | Evidence-manifest SHA-256 |
|---|---|---|---|---|
| Debug 1 | `cbe75c955dad38fe8999c4a746c6f4ef2766d73aed3e7ef70f16084970eb8bb6` | `13e460fe2ecef5fa1f8939fe46f4a95c4375ff35d37435753b8cc8fa313fab85` | `79858fe61a377bc8795eac499628c1ba533dfb0ee2029d12bccadec8e3fbf61a` | `1d502e7481e15d5ec7db8b0808037649f9eee08fb343d29787a615cfb90f786c` |
| Debug 2 | `60a353889d68108a142dd43fc7b179e21ddbdee854e9f162b48a8e7c874eb43f` | `21ad5fe629e40e7c16134df23db13c49cac1d6dbdbe766b3d111fc046bb712c4` | `09a15b6593e3a6d968b28bc161dc0ca6ef35b579eb6f3725a0da7b37003055fd` | `fcaf40cf836a08f642fcfa8cb77da708870b61dd795d52bfd9ad88ff69be97cc` |
| Debug 3 | `9c66f5c3a92a09d6aa007413950c1cca7a88922b5702dd69fda28ff60c0f6a34` | `b638c8545af783a6cb2b8b192c4b10a1e90bc9845147c9781b93f4960c7bf816` | `c1a294fb1f685655e716ed8311a0216197c5674010d3fd5fae12535464b83395` | `0c10ad4cbd9724d48c7c25f42291716b1468592a848f031cc99eddef136a59dd` |
| Release 1 | `ddb0167554cb6f1e67adc03665369d768aeb980611e3cee980aaf4660fe35867` | `d92926cb34a3e585c50937d6b773cb931cfa5b3f140163903773df8c6d369c73` | `e3c21d138f1ab6d2fbb2fd4132d41225020a63dc3ddcd8e193d3f3977d17d147` | `0e5eb045b1b95ff8ad1b140af594bacdf8f208985b5a3934a18d7a568857d957` |
| Release 2 | `513777480b74f4e7a946256ab9c657fc437d4cf42a7423e5061104ff5ed970ae` | `a8361ff89597fd16c5ae4705cddfb446e1acae5f085d632bbadcf847acfc39fe` | `c82983c59044a024316c1056007cf7e81c9209ddbe2f50dd60c6a40867cfab20` | `da08390f737d99ea1f70f3347eec4ca67c6c72c5553fc9421ee1d0e343eaf6a4` |
| Release 3 | `1f02a44a62853b5a0f9209dcf7a8fa196461777b7b9eb0e4a2ee71c7a7c447b8` | `d0e98d9258d9d1458a4986e536e0b231f942b44cef5a26a04dd9d12552e57348` | `4ecc5b64d58316fafce68ef1a62581440802fb01ee507a9add4e519f3577498d` | `ee420d0fae18837161486e7b560b52051c84573e98b7e0aa0f24562af9af0ab9` |

### Reproduction

The build wrapper archives the `HEAD` of the checkout that contains the invoked script. Therefore,
running it from a later documentation commit does **not** reproduce this baseline. Start from any
repository checkout that already contains the measured object, create a fresh detached worktree at
the full measured commit, prove that worktree is detached and clean, and place every new build/run
artifact under one newly allocated prefix:

```sh
set -euo pipefail

F2_MEASURED_COMMIT=c871ddf5c66c17f03fd9456b53f79411f9b2e979
F2_REPOSITORY_ROOT="$(git rev-parse --show-toplevel)"
F2_REPRO_ROOT="$(/usr/bin/mktemp -d /private/tmp/plainsong-f2-c871ddf-repro.XXXXXX)"
F2_SOURCE_WORKTREE="$F2_REPRO_ROOT/source"

git -C "$F2_REPOSITORY_ROOT" cat-file -e "${F2_MEASURED_COMMIT}^{commit}"
git -C "$F2_REPOSITORY_ROOT" worktree add --detach \
  "$F2_SOURCE_WORKTREE" "$F2_MEASURED_COMMIT"
test "$(git -C "$F2_SOURCE_WORKTREE" rev-parse HEAD)" = "$F2_MEASURED_COMMIT"
if git -C "$F2_SOURCE_WORKTREE" symbolic-ref -q HEAD >/dev/null; then
  echo "F2 reproduction worktree must be detached" >&2
  exit 1
fi
test -z "$(git -C "$F2_SOURCE_WORKTREE" status --porcelain=v1 --untracked-files=all)"
cd "$F2_SOURCE_WORKTREE"

Scripts/build-editor-find-f2-performance-gate.sh \
  Debug "$F2_REPRO_ROOT/debug-build"
Scripts/build-editor-find-f2-performance-gate.sh \
  Release "$F2_REPRO_ROOT/release-build"

for F2_RUN in 1 2 3; do
  Scripts/run-editor-find-f2-performance-gate.sh Debug \
    "$F2_REPRO_ROOT/debug-build" \
    "$F2_REPRO_ROOT/debug-run${F2_RUN}.xcresult" \
    "$F2_REPRO_ROOT/debug-run${F2_RUN}.log"
done

for F2_RUN in 1 2 3; do
  Scripts/run-editor-find-f2-performance-gate.sh Release \
    "$F2_REPRO_ROOT/release-build" \
    "$F2_REPRO_ROOT/release-run${F2_RUN}.xcresult" \
    "$F2_REPRO_ROOT/release-run${F2_RUN}.log"
done
```

`mktemp` makes these output prefixes fresh. Do not substitute the retained artifact paths listed
above: those paths are immutable evidence, and both wrappers intentionally reject reuse. The new
run is a reproduction attempt whose results must be reported separately; it does not replace or
silently mix with the six retained samples.

Both wrappers reject a dirty worktree, CI budget mode, reused output paths, source/build
mismatches, and post-run mutation. The build wrapper archives the exact commit, generates the
project inside a source snapshot, resolves packages once, seals the consumed source/package
inputs read-only, then uses `-disableAutomaticPackageResolution` for `build-for-testing`.
`ENABLE_TESTABILITY=YES` is added only for Release because the reusable harness observes internal
EditorKit transition state; it does not enable `DEBUG` compilation or change the production
debounce.

Both builds have source-archive SHA-256
`f0b84f1b43145b443364b28666710166debcd0c0342dad6e90092c2c70e55506` and pre-generation
source-tree SHA-256
`51b3c5309d67603ac8a4f298deed795d3c4afa597f0ac83cfcc3632e0abfda94`.
The Debug/Release generated build-input hashes are respectively
`688be8f5e444142d281b1a5e3167e607c27cf410ffdd1d968b1988b10668eb80` and
`4f18738efceebe42159e8413a3d61cfdba81282ebb4b507edaac4a00707babdc`.
Both resolved-package-input hashes are
`ed48178719a6c72d2880d3972e900d3bbe51f180d13e01dffd452de936f779c3`.
That last digest deliberately covers the consumed checkout bytes (excluding checkout/submodule
`.git` administration), all artifact bytes, and `workspace-state.json`; mutable top-level bare
repository caches are not treated as source provenance. Unknown top-level entries fail closed.
The Debug/Release build-manifest hashes are
`f686590407861591caaddc30e96987e5bf927f9906f4692c15ffdcac327e10d0` and
`e8a8f02f83c8b4b919aa697fefa148f3bbee5c3f65850d731bd5526970fa861e`.

### Procedure and scope

The query probe starts its clock immediately before
`AppState.handleEditorFindQueryTextChange`. It includes App query publication, the production
150 ms debounce, detached `TextSearchEngine` matching, revision/query fencing, main-actor session
application, and App presentation. Every scenario gets one unmeasured warm-up and three measured
samples. Every sample hard-asserts the exact retained count/truncation shape, first and last retained
match endpoints, and that the matcher observed itself off the main thread.

| Shape | Deterministic pattern | Expected result | Exact retained endpoints |
|---|---|---|---|
| Zero | `plainsong-f2-zero-hit` | 0 retained; not truncated | first `nil`; last `nil` |
| Sparse | `generated sections: 1274` | 1 retained; not truncated | first = last: `NSRange(location: 1_048_904, length: 24)`, line 33,140 |
| Dense | `section` (default smart case) | 10,000 retained; truncated by the 10,001st overflow match | first: `NSRange(location: 399, length: 7)`, line 15; last retained: `NSRange(location: 914_752, length: 7)`, line 28,901 |

The production-hosted probe mounts the shipped `WorkspaceWindow` in a 1,100 × 720
`NSHostingController`/`NSWindow`, injects the real `AppState`, and waits for both the production
`MarkdownSTTextView` and shipped `EditorFindBar` query `NSTextField`. It opens find through
`showOrRefocusEditorFind()`, drives the dense query through
`handleEditorFindQueryTextChange`, and confirms the visible `1 / 10000+` truncated presentation.
Mount, find-bar creation, and dense-query priming all occur before measured editing starts.

With the real editor already focused, each of five measured edits calls its native
`insertText("x", replacementRange: .notFound)` at the mounted visible-range start. **Admission**
starts immediately before that call and stops when it returns. **Root state-update receipt** stops
at the timestamp captured synchronously when the root's test-only
`NSViewRepresentable.updateNSView` enters with the new document revision, bar/query still present,
and the old find presentation invalidated. The receipt is stored with a monotonic generation and
bounded history so a later update cannot overwrite the awaited snapshot.

Before the first suspension, hard assertions require the completed-match count to remain unchanged,
`session == nil`, and no pending navigation. This proves that the old presentation was invalidated
and no new match completion or navigation was applied synchronously; it does not prove that no
matcher work began synchronously. The polling loop calls `layoutSubtreeIfNeeded()` to drive pending
SwiftUI/AppKit work, so incidental layout may occur before the timestamped root receipt. The
endpoint does not require or prove that child layout completed. After finding the receipt, the test
forces any remaining layout and proves the production editor representable updated. The eventual
recompute is outside the two measured intervals and must run off-main, retain/truncate the same
10,000 matches, and shift both endpoint locations by exactly the insertion count while preserving
their line numbers.

The receipt proves entry into the root SwiftUI/AppKit update transaction. It excludes compositor
presentation and physical keyboard delivery, and does not require or prove child-layout completion;
therefore it does not close the separate `<16 ms` keystroke-to-screen criterion or claim equality
with a find-closed distribution.

### Raw query-completion results

All values are milliseconds. Bold values are the median of the three samples in that cell.

| Configuration / run | Zero samples; median | Sparse samples; median | Dense samples; median |
|---|---|---|---|
| Debug 1 | `[234.121, 236.297, 233.791]`; **234.121** | `[242.229, 259.028, 275.307]`; **259.028** | `[647.930, 671.841, 690.992]`; **671.841** |
| Debug 2 | `[322.109, 267.309, 295.671]`; **295.671** | `[237.678, 251.572, 302.016]`; **251.572** | `[619.368, 614.958, 609.108]`; **614.958** |
| Debug 3 | `[244.517, 256.913, 234.795]`; **244.517** | `[243.530, 244.823, 266.772]`; **244.823** | `[652.836, 667.837, 654.409]`; **654.409** |
| Release 1 | `[166.167, 178.732, 173.033]`; **173.033** | `[183.565, 187.881, 178.594]`; **183.565** | `[244.551, 237.605, 245.864]`; **244.551** |
| Release 2 | `[179.494, 176.742, 171.902]`; **176.742** | `[185.900, 181.848, 187.980]`; **185.900** | `[248.075, 266.569, 245.316]`; **248.075** |
| Release 3 | `[165.195, 179.275, 178.648]`; **178.648** | `[175.217, 184.089, 185.648]`; **184.089** | `[237.652, 238.846, 239.970]`; **238.846** |

### Raw production-hosted edit results

All values are milliseconds. Bold values are the five-sample median; the last value in the receipt
cell is the diagnostic maximum. Budgets apply to each run's median, not its maximum.

| Configuration / run | Admission samples; median | Root state-update receipt samples; median; maximum |
|---|---|---|
| Debug 1 | `[1.587, 1.296, 16.514, 1.206, 1.094]`; **1.296** | `[6.072, 4.297, 19.593, 4.353, 4.055]`; **4.353**; max **19.593** |
| Debug 2 | `[1.784, 1.246, 16.573, 1.090, 1.796]`; **1.784** | `[8.970, 4.885, 20.772, 5.183, 8.635]`; **8.635**; max **20.772** |
| Debug 3 | `[1.664, 3.271, 25.264, 1.215, 1.655]`; **1.664** | `[6.272, 6.850, 29.979, 4.621, 6.010]`; **6.272**; max **29.979** |
| Release 1 | `[1.695, 1.080, 14.444, 1.069, 1.013]`; **1.080** | `[7.171, 5.644, 17.877, 4.027, 4.355]`; **5.644**; max **17.877** |
| Release 2 | `[1.543, 1.164, 14.386, 1.015, 1.138]`; **1.164** | `[5.832, 4.248, 17.791, 4.564, 4.788]`; **4.788**; max **17.791** |
| Release 3 | `[1.292, 1.075, 1.033, 0.984, 0.975]`; **1.033** | `[6.811, 4.999, 3.745, 3.774, 3.731]`; **3.774**; max **6.811** |

### Budgets and enforcement

The five round ceilings were already present in measured commit `c871ddf` before the
authoritative sequence. They were derived from earlier Debug measurements, remain defensible
against this final same-source rerun, and were not widened after any retained result. Release is
confirmation only and did not justify a threshold.

| Metric | Debug run medians | Debug median of run medians | Release run medians | Release median of run medians | Budget | Budget / slowest Debug run median |
|---|---|---:|---|---:|---:|---:|
| Zero query completion | 234.121, 295.671, 244.517 | **244.517** | 173.033, 176.742, 178.648 | **176.742** | < 400 ms | 1.35x |
| Sparse query completion | 259.028, 251.572, 244.823 | **251.572** | 183.565, 185.900, 184.089 | **184.089** | < 400 ms | 1.54x |
| Dense-truncated query completion | 671.841, 614.958, 654.409 | **654.409** | 244.551, 248.075, 238.846 | **244.551** | < 1,100 ms | 1.64x |
| Native edit admission | 1.296, 1.784, 1.664 | **1.664** | 1.080, 1.164, 1.033 | **1.080** | < 5 ms | 2.80x |
| Root state-update receipt | 4.353, 8.635, 6.272 | **6.272** | 5.644, 4.788, 3.774 | **4.788** | < 15 ms | 1.74x |

Query gates enforce each run's three-sample median. The production-hosted gates enforce each run's
five-sample admission and receipt medians. Deterministic fixture identity, endpoints,
count/truncation, session invalidation, transition generation, and off-main assertions remain hard
everywhere. Wall-clock thresholds are hard locally and print informational failures on hosted CI
under R15.

### Retained cold-path tail samples

Five of the six retained runs have a large synchronous sample at exactly the third insertion:
Debug admission is 16.514–25.264 ms in all three runs, and Release admission is 14.386–14.444 ms
in runs 1–2. The corresponding receipt samples are 19.593–29.979 ms in Debug and
17.791–17.877 ms in Release. Release run 3 does not reproduce the spike. No sample is discarded;
the complete arrays above retain both the slow and non-slow shapes.

Repeated sampling attributed that spike to the editor/preview scroll-sync bridge's
`EditorScrollLineIndex.init(text:)`: after the text-change observer invalidates its cache, the next
visible-line request synchronously rebuilds line starts by walking the full 1 MiB string's UTF-16
units. This O(n) main-actor work extends `insertText` admission. It is not find matching: before
every await the probe proves no new match result or navigation was applied and the old
session/navigation are gone, while the later exact dense recompute again reports that it ran
off-main.

Time-profile investigation localized the repeated shape to the editor/preview scroll-sync
line-index rebuild. That diagnostic was not used as an authoritative timing run. The final
same-source arrays above are the only retained baseline numbers. The cold-path production debt
remains real even though it is not universal; the median-based F2 proxies pass, while the full
`<16 ms` keystroke-to-screen criterion remains open.

### Narrow pre-measure warning exception

Each of the six authoritative logs contains exactly three
`Modifying state during view update, this will cause undefined behavior.` warnings, all before
measured editing begins: two while the production editor representable mounts and one while the
dense prime applies its initial navigation. The six paired `.xcresult` bundles each coalesce those
three console emissions into one Runtime Warning issue.

The test prints one unambiguous
`F2_WARNING_PHASE_BEGIN id=<UUID> edits=5` line immediately before the five-edit loop and the
matching `F2_WARNING_PHASE_END` immediately after it. The six phase IDs are:

| Run | Phase ID | Raw known warnings |
|---|---|---|
| Debug 1 | `5a7bd097-bc00-4050-b354-49f52433b7ee` | pre 3; measured 0; post 0 |
| Debug 2 | `463f3270-d8d2-4723-945a-e7f61c5b613c` | pre 3; measured 0; post 0 |
| Debug 3 | `5dd77f2b-20a5-477d-8cd3-c882bb8345ba` | pre 3; measured 0; post 0 |
| Release 1 | `55e59e44-3c6a-4130-98db-c8a63113cd58` | pre 3; measured 0; post 0 |
| Release 2 | `5f06379b-1e54-4801-8b23-6035252d15dc` | pre 3; measured 0; post 0 |
| Release 3 | `4b7a2305-fa36-48f3-a55b-bb5fa73fca7a` | pre 3; measured 0; post 0 |

`Scripts/run-editor-find-f2-performance-gate.sh` automatically invokes
`Scripts/check-editor-find-f2-warning-phase.py` before accepting a run. The checker verifies the
sealed raw-log and raw-result digests, exactly one ordered marker pair with the same UUID and
`edits=5`, exactly three known warnings before `BEGIN`, zero known warnings between `BEGIN` and
`END`, zero after `END`, zero other SwiftUI diagnostics, and two `local-hard` budget markers. It
also requires the `.xcresult` inspection copy to report exactly two passing tests, zero failures,
and exactly one coalesced Runtime Warning issue with the known message. Thus the raw log, rather
than coalesced issue count, is authoritative for warning phase.

A negative control moved one known warning from before `BEGIN` to immediately after `BEGIN` in a
copy of Debug run 1's log while retaining the same coalesced `.xcresult`. The checker exited 1 with:

```text
F2 WARNING CHECK FAIL: known warning occurred during the five measured edits at lines [113]
```

That proves a warning during the five measured edits fails even when `.xcresult` still exposes only
the same single coalesced issue. The temporary negative-control copies were removed and are not
baseline artifacts.

The `.xcresult` issue has no `sourceURL` in Debug and generically attributes
`PerformanceTests/EditorFindProductionHostSupport.swift` in Release, so it proves warning
presence but not the phase or origin of each console emission. Break-at-warning diagnosis localized the
mount pair to the pre-F2 `MarkdownTextView.makeNSView` setup ordering: the coordinator becomes the
text delegate and initial selection is assigned before the coordinator enters its update guard, so
the selection callback writes the SwiftUI selection binding during view construction. Running the
pre-existing hosted
`AppBackedEditorPerformanceTests.testHostedPublicEditorCurrentRevisionInputAndMarkedTextStayWithinFrameBudget`
without the F2 root receipt produces the same coalesced Runtime Warning family in
`/private/tmp/f2-warning-appbacked.xcresult`, confirming that the family is not introduced by the
receipt. That bundle does not retain a per-emission console log and is not used to prove the
authoritative two-emission mount count; that count comes from each of the six retained F2 logs.

The dense-prime warning localizes to the pre-F2 navigation path assigning the applied selection.
In the probe, `primeProductionWorkspaceFind` returns before the begin marker and measured-edit loop,
so this navigation warning is independently proven pre-measure by each raw log. The test-only root
receipt is plain storage and publishes no SwiftUI state; it is not the warning source. The
concurrently F8-owned `MarkdownTextView`, coordinator, and highlight files were not changed to
eliminate these pre-existing warnings.

This baseline is accepted only under that exact three-warning, pre-measure exception and is not
warning-free UI evidence. Under the current checker, any signature/count change — including fewer
warnings — or any warning at or after `BEGIN` fails the run. A relevant editor/F8/toolchain/OS
change is not compared by that checker; it invalidates this baseline and requires a fresh six-run
evidence set. If the production path is fixed, the checker and this exception must be deliberately
replaced with a zero-warning contract before new evidence is accepted.

### F8 boundary

F8 remains deferred. Commit `c871ddf` has no production highlight-all apply/clear implementation,
so this work records no highlight preservation, apply-latency, or clear-latency claim. The exact
fixture, scenarios, full `WorkspaceWindow` host, and generation-stamped receipt are reusable after
that production surface lands; no unmerged F8 behavior was optimized or manufactured here.

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
