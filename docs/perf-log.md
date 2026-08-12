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

This is the retained historical baseline for the F2 query-completion and production-hosted
state-update receipt proxy samples. The six runs measured exact clean source
`c871ddf5c66c17f03fd9456b53f79411f9b2e979`; historical tooling commit
`03ffd7024ac248977a802bb46b7f0413293979cd` owns the exact capture, retained-pack builder, and
auditor bytes used to produce and retain them. The current responsibility-split, isolated tooling
audits those historical bytes independently; it did **not** produce the six runs. Keeping those
identities separate prevents a later documentation/tooling commit from being misrepresented as
the measured product source. The historical process classifier, however, exempted every
same-path frozen host rather than one host correlated with the launch. Those bytes therefore do
not prove absence of an uncorrelated target process; process isolation is an explicit open
boundary unless a fresh six-run pack is captured with the corrected maintained tooling.

| Field | Value |
|---|---|
| Date | 2026-08-08 (Asia/Taipei) |
| Branch | `codex/editor-find-f2-performance-probe`; `origin/main` at `250e91e16a1fd5339096ec96b84fcfe6e9790c4c` is an ancestor |
| Measured source commit | `c871ddf5c66c17f03fd9456b53f79411f9b2e979` |
| macOS | macOS 27.0 (26A5388g) |
| Xcode | Xcode 27.0 (27A5194q) |
| XcodeGen | 2.45.4; binary SHA-256 `3b483413a801394b00adb2fabf3c06ff8f800c73c8698e1f9a9d8a95d73939ef` |
| Machine | MacBook Pro (MacBookPro18,3), Apple M1 Pro (8 cores), arm64, 16 GB RAM |
| Fixture | `Fixtures/large-1mb.md`: 1,048,962 bytes; SHA-256 `d174f48ea6175db568abe44e5b71e82ee92f1cf9c0ed081d8f8308cc1961d247` |
| Tests | `EditorFindPerformanceTests.testLargeFixtureFindQueryCompletionForZeroSparseAndDenseCases`; `...testProductionWorkspaceFindOpenEditAdmissionAndStateReceiptStayWithinMeasuredBudgets` |
| Historical evidence-tooling commit | `03ffd7024ac248977a802bb46b7f0413293979cd` |
| Result | All retained samples are within the named proxy budgets — three Debug and three Release runs, two tests per run, zero test failures. Compact and owner-local full-artifact audits authenticate all six historical runs, but do not repair their process-correlation flaw. Historical process isolation, independent durable retention, and the other open boundaries below prevent overall F2 closure. |

The Git-versioned compact evidence is retained at
`docs/evidence/editor-find-f2-c871ddf-retained-pack/`: 145 files (916 KiB), including all six raw
logs, per-file digests, boundary/competition-monitor records, normalized xcresult summaries,
warning checks, manifests, and the exact retained capture/auditor sources. Its `manifest.json`
SHA-256 is `c7d1a3c68285aa0aac35914fe7d4d60c1bfbc8401b0055e689365b1bbe9989c5`;
the `SHA256SUMS` file SHA-256 is
`23d3ec514e1a99f65093dede22af190dece22a936d56e999c2bf0740b5bb50bd`.

The 1.0 GiB source snapshots, resolved packages, frozen products, raw/inspection xcresults, and
build manifests are currently present only in the owner's purgeable local artifact root
`/private/tmp/plainsong-f2-evidence-review.SnCT6g/full-artifacts`. A full audit rehashed that root
and passed six runs, but `/private/tmp` is not durable, Git does not carry it, and no independently
retained copy is authorized or claimed. Loss of that root invalidates the full-artifact audit and
requires fresh evidence before that audit can pass again.
The versioned compact audit is intentionally reported as `PARTIAL runs=6` unless that full root is
supplied. Both audit modes keep historical uncorrelated-target-process isolation, independent
durable retention, full-keystroke-to-screen, F8 apply/clear, F9, and combined-tip open.

### Historical provenance and current operator trust root

The retained pack is byte-for-byte unchanged by the integration. Its reference tree and manifest
pin the `03ffd70` historical capture/auditor family, including the per-run combined capture digest
`5a8ff6ca023de2954847d3e9903413daab7b52434ce24efac8536f9b016d5136`.
The measured source commit preserves the monolithic build and runner bytes used by the runs; they
are historical artifacts, not maintained large-file exceptions in the current checkout.

| Trust-root item | SHA-256 |
|---|---|
| Historical measured-source build wrapper (`c871ddf`) | `02249b49aabc80286cb17e668edebfeef987a9ae4abe75d6ee3aeceeeb084598` |
| Historical measured-source runner (`c871ddf`) | `90e5aa9edd01a96132b80a092421c2cfc47c7e6d2944f1876bf8ddcf76edea8d` |
| Historical outer capture wrapper (`03ffd70`) | `2a704978fd73e3a15cc383882d01440e099927eff3672ebd31bfa39420df56bf` |
| Historical pack builder / auditor (`03ffd70`) | `11bce3e0fbaa4419f430cbb814749d3bdb9825a0692a73fba5f9f90b653440a9` / `605a56d322ecb253f59f82e4c9787df7bd922a76bb5ec6e6e910e1cc0adfb819` |
| Current `Scripts/editor-find-f2-tooling.sha256` | `c5224b734b99a64dcd96ace010ae9583ab1b32ff3950fd9744342bd622fa7eec` |
| Current inventory verifier | `047aca8f71e33ff6907f447546111eecbbb0bdea391ad98b2d1681c0ac4edb0c` |
| Current isolated bootstrap | `b67dac167543c83b0c8c4e1844dbe2421c1d16a6bcff301603bf2c3ac0bfa59d` |
| Current capture schema | `156177ae6c047e7f1295381c557c440263dcac63d48a3fbaf01dd69d4bcb3d56` |
| Current auditor / builder entry points | `ed9ad47f21d6a4df4ae1dc24a76c669e9eac11548fbdcab1bd0a49722cf3a9f2` / `6cab5471e11f06cb9b853a54c209fd9f87279330975da696a74c33c5094b3b4f` |
| Current capture / runner / build entry points | `8317ac44819387ac0b53167643be3c3f5e023b4ee1d6c3cb2dad1f38686c7f8e` / `0d220849377cd21d11207ebd35056b7ce9a21f93df23592945fd9ee5bcd169c5` / `9c54513d118bf150d52aa8f781933df98fc2141959c988e67dcf42718cd9e6a2` |

All 36 maintained executable/support modules are in the external inventory. Current Python entry
points require isolated `-I` startup, verify canonical current-UID-owned non-symlink paths with no
group/world write or ACL `allow`, hash-pin the bootstrap and exact package inventory, then import.
Current shell entry points require `bash -p`; the capture and runner wrappers pin every sourced
module before loading it, and the current build/runner entry points also pin the artifact hasher
they execute. Their parent shell sets `umask 077` with the Bash builtin, and every command before
owner/hash verification is either a shell builtin or a fixed absolute system path; inherited
`PATH` is not consulted. Maintained digest paths use empty-environment `/usr/bin/python3 -I -S`, not ambient
Perl-backed `shasum`. The exact pack inventory and full-artifact audit additionally reject
symlinks, foreign owners, group/world writers, ACLs, and unsupported entries before exact rehash;
the full audit then cross-binds all nine retained artifacts to the compact evidence manifest and
its exact retained build manifest. The current schema independently anchors the retained source
archive (`f0b84f1b…`) and its reconstructed logical tree (`51b3c530…`): compact mode rejects a
rewritten archive claim, and full mode parses the uncompressed tar without extraction, rejects
unsafe members, and recomputes the tree hash. A retained test-runner input must be the non-overlapping
direct child `Build/Products/*.xctestrun`, not an arbitrary regular build product. Historical
format-2 packs keep their exact reference set;
newly built format-3 packs additionally retain the isolated bootstrap required by their thin
auditor/builder wrappers. Pathname reopening cannot exclude a concurrent mutation by another
process already trusted as this same UID; that boundary is explicit and is not described as
race-proof loading.

The authoritative current-checkout audit sequence is:

```sh
set -euo pipefail
F2_CHECKOUT="$(/usr/bin/git --no-replace-objects rev-parse --show-toplevel)"
F2_PACK="$F2_CHECKOUT/docs/evidence/editor-find-f2-c871ddf-retained-pack"
F2_FULL_ROOT=/private/tmp/plainsong-f2-evidence-review.SnCT6g/full-artifacts
F2_PACK_INVENTORY_SHA=23d3ec514e1a99f65093dede22af190dece22a936d56e999c2bf0740b5bb50bd

f2_sha256() {
  /usr/bin/env -i LANG=C LC_ALL=C PATH=/usr/bin:/bin \
    /usr/bin/python3 -I -S -c \
    'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' \
    "$1"
}

test "$(f2_sha256 "$F2_CHECKOUT/Scripts/editor-find-f2-tooling.sha256")" = \
  c5224b734b99a64dcd96ace010ae9583ab1b32ff3950fd9744342bd622fa7eec
test "$(f2_sha256 "$F2_CHECKOUT/Scripts/check-editor-find-f2-tooling-inventory.py")" = \
  047aca8f71e33ff6907f447546111eecbbb0bdea391ad98b2d1681c0ac4edb0c
test "$(f2_sha256 "$F2_PACK/manifest.json")" = \
  c7d1a3c68285aa0aac35914fe7d4d60c1bfbc8401b0055e689365b1bbe9989c5
test "$(f2_sha256 "$F2_PACK/SHA256SUMS")" = "$F2_PACK_INVENTORY_SHA"
"$F2_CHECKOUT/Scripts/check-editor-find-f2-tooling-inventory.py"
set +e
"$F2_CHECKOUT/Scripts/check-editor-find-f2-retained-evidence.py" \
  "$F2_PACK" --expected-inventory-sha256 "$F2_PACK_INVENTORY_SHA"
F2_COMPACT_STATUS=$?
set -e
test "$F2_COMPACT_STATUS" -eq 3
"$F2_CHECKOUT/Scripts/check-editor-find-f2-retained-evidence.py" \
  "$F2_PACK" --allow-partial \
  --expected-inventory-sha256 "$F2_PACK_INVENTORY_SHA"
"$F2_CHECKOUT/Scripts/check-editor-find-f2-retained-evidence.py" \
  "$F2_PACK" --artifact-root "$F2_FULL_ROOT" \
  --expected-inventory-sha256 "$F2_PACK_INVENTORY_SHA"
```

Default compact exit 3 is the expected `PARTIAL/OPEN` result; `--allow-partial` makes that
explicit and returns 0. The final command returns 0 only while the owner-local full root is still
present, owner-controlled, ACL-free, and byte-identical. It does not turn that purgeable copy into
independent durable retention.

| Run | Raw log SHA-256 | Raw `.xcresult` SHA-256 | Warning-check SHA-256 | Evidence-manifest SHA-256 |
|---|---|---|---|---|
| Debug 1 | `98bc3307d0759958ac0e5cf29a34b467c608927c02543d13f7dcff806362f2d5` | `54a7445954b87725386204da01102de81e7e5abfb37a11770c7e1c3696f02866` | `66012706d2338217c1793bab0d82fa7f96121bfcfcf635087b00e95ba51d4d45` | `0a034776d0b7f214b35309382a515f082e57b817e305516d3b518fff8e912916` |
| Debug 2 | `b6dba2c69b5b240e9d7295876121df8c86d3669ed4b2899360ef74984d6e7f82` | `6acdc2bcb01f847ec6db4bed30f47431187892d4853457e6daab04c0210ee8a3` | `2619744ecafaef54a2db9063f51ffd4c02bc96cf0fb0028f26c504e6974ad9c4` | `97c21e67c6f7ae18e62890d1384a30a548eaeab50ee2d14dd9e3c52cb7e59e6a` |
| Debug 3 | `e82d1876fa6e0fa0ddb734d20f506529b00c6951f57bb6fa4090a53606d3e620` | `e1c5830dc4c9be361d0b3bde0989149d8c75678daadb212994ae85e092025f5e` | `f4eb98a8f1304de4c7380960a23b9f0dbfaa6b61c41bd1cae518751d1f9ce582` | `b129e9e4373d40d94883afc372ec2d9e2570f1ac62d436329dcc8d12922c0028` |
| Release 1 | `2fa204b2f074d289b68b402019429fb93a8616530e846b56e3c6bd0e167fc600` | `9e953cc6f1f63b806c2e5c4e3fdd7a325173f543b52a9756d1e5768961bd1bf9` | `6fd7532de227b69d791712bcc76d15ac8da09ad6216c2b83b8e8531ed5e6c562` | `a00663e2c981daeab502690825edde00f7f511f374bae3776373a45a9a07fa5e` |
| Release 2 | `c87d7e33eb07a073b646bb2e927e9cf83da76563e00a7bd8c2ed71a2658a4c27` | `4f1a203d853e74d72f91890a43ed4ca1bfcb314294294e0626764cedb8c9155a` | `e7aea10447d4c1aed1d0b65dbaaef0c2a4a1f0b88825e8323bbfd0126175cbb3` | `8da37e1d3294dbb8e0bd9b60a249e8a7f50769aa308a08c0b84f6930e20ce2c3` |
| Release 3 | `25b1af1acca12dee4147556d9c08d9b6b97c4739430ae506a697356842ce2748` | `c13e9ec49c8fba416e8cfe01f9aa92e2ae1a1cfa008a00465e007a518c9a4aba` | `1cbb9d8e83c9700470d8ceca77b1ad3c79d36adb9a611881f9edf137a5c07cd5` | `4aa9893fc3baaba624d14e354485e3d7e10edf1aa29362ae57a65d92eaecaba4` |

### Reproduction with fresh outputs

The product source, historical evidence tooling, and current audit tooling have different
identities. Reproduce the measured mechanism with one clean detached source worktree at the full
`c871ddf` commit and one clean detached historical-tooling worktree at the full `03ffd70` commit.
The source worktree owns the exact build wrapper and product tests; the historical-tooling worktree
owns the exact outer capture, process monitor, pack builder, and auditor that produced this pack.
The current checkout is used only to verify its maintained trust inventory and to independently
audit the new pack. Every output goes below a newly allocated mode-0700 root, so none of the six
versioned paths or hashes can be reused accidentally. This workflow needs enough free disk for two
builds plus a new full-artifact root.

```sh
set -euo pipefail

F2_MEASURED_COMMIT=c871ddf5c66c17f03fd9456b53f79411f9b2e979
F2_TOOLING_COMMIT=03ffd7024ac248977a802bb46b7f0413293979cd
F2_REPOSITORY_ROOT="$(/usr/bin/git --no-replace-objects rev-parse --show-toplevel)"
F2_REPRO_ROOT="$(/usr/bin/mktemp -d /private/tmp/plainsong-f2-c871ddf-repro.XXXXXX)"
F2_SOURCE_WORKTREE="$F2_REPRO_ROOT/source"
F2_TOOLING_WORKTREE="$F2_REPRO_ROOT/tooling"
F2_ACCOUNT_NAME="$(/usr/bin/id -un)"
F2_ACCOUNT_HOME="$(/usr/bin/python3 -I -S -c \
  'import os,pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')"
F2_DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer

f2_sha256() {
  /usr/bin/env -i LANG=C LC_ALL=C PATH=/usr/bin:/bin \
    /usr/bin/python3 -I -S -c \
    'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' \
    "$1"
}

test "$(f2_sha256 "$F2_REPOSITORY_ROOT/Scripts/editor-find-f2-tooling.sha256")" = \
  c5224b734b99a64dcd96ace010ae9583ab1b32ff3950fd9744342bd622fa7eec
test "$(f2_sha256 "$F2_REPOSITORY_ROOT/Scripts/check-editor-find-f2-tooling-inventory.py")" = \
  047aca8f71e33ff6907f447546111eecbbb0bdea391ad98b2d1681c0ac4edb0c
"$F2_REPOSITORY_ROOT/Scripts/check-editor-find-f2-tooling-inventory.py"

/usr/bin/git -C "$F2_REPOSITORY_ROOT" --no-replace-objects \
  cat-file -e "${F2_MEASURED_COMMIT}^{commit}"
/usr/bin/git -C "$F2_REPOSITORY_ROOT" --no-replace-objects \
  cat-file -e "${F2_TOOLING_COMMIT}^{commit}"
/usr/bin/git -C "$F2_REPOSITORY_ROOT" --no-replace-objects worktree add --detach \
  "$F2_SOURCE_WORKTREE" "$F2_MEASURED_COMMIT"
/usr/bin/git -C "$F2_REPOSITORY_ROOT" --no-replace-objects worktree add --detach \
  "$F2_TOOLING_WORKTREE" "$F2_TOOLING_COMMIT"
test "$(/usr/bin/git -C "$F2_SOURCE_WORKTREE" --no-replace-objects rev-parse HEAD)" = \
  "$F2_MEASURED_COMMIT"
test "$(/usr/bin/git -C "$F2_TOOLING_WORKTREE" --no-replace-objects rev-parse HEAD)" = \
  "$F2_TOOLING_COMMIT"
! /usr/bin/git -C "$F2_SOURCE_WORKTREE" symbolic-ref -q HEAD >/dev/null
! /usr/bin/git -C "$F2_TOOLING_WORKTREE" symbolic-ref -q HEAD >/dev/null
test -z "$(/usr/bin/git -C "$F2_SOURCE_WORKTREE" status --porcelain=v1 --untracked-files=all)"
test -z "$(/usr/bin/git -C "$F2_TOOLING_WORKTREE" status --porcelain=v1 --untracked-files=all)"

test "$(f2_sha256 "$F2_SOURCE_WORKTREE/Scripts/build-editor-find-f2-performance-gate.sh")" = \
  02249b49aabc80286cb17e668edebfeef987a9ae4abe75d6ee3aeceeeb084598
test "$(f2_sha256 "$F2_SOURCE_WORKTREE/Scripts/run-editor-find-f2-performance-gate.sh")" = \
  90e5aa9edd01a96132b80a092421c2cfc47c7e6d2944f1876bf8ddcf76edea8d
test "$(f2_sha256 "$F2_TOOLING_WORKTREE/Scripts/capture-editor-find-f2-authoritative-run.sh")" = \
  2a704978fd73e3a15cc383882d01440e099927eff3672ebd31bfa39420df56bf
test "$(f2_sha256 "$F2_TOOLING_WORKTREE/Scripts/build-editor-find-f2-retained-pack.py")" = \
  11bce3e0fbaa4419f430cbb814749d3bdb9825a0692a73fba5f9f90b653440a9
test "$(f2_sha256 "$F2_TOOLING_WORKTREE/Scripts/check-editor-find-f2-retained-evidence.py")" = \
  605a56d322ecb253f59f82e4c9787df7bd922a76bb5ec6e6e910e1cc0adfb819

f2_historical_bash() {
  /usr/bin/env -i \
    DEVELOPER_DIR="$F2_DEVELOPER_DIR" \
    HOME="$F2_ACCOUNT_HOME" \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    LOGNAME="$F2_ACCOUNT_NAME" \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    TMPDIR=/private/tmp \
    USER="$F2_ACCOUNT_NAME" \
    /bin/bash -p "$@"
}

f2_historical_bash \
  "$F2_SOURCE_WORKTREE/Scripts/build-editor-find-f2-performance-gate.sh" \
  Debug "$F2_REPRO_ROOT/debug-build"
f2_historical_bash \
  "$F2_SOURCE_WORKTREE/Scripts/build-editor-find-f2-performance-gate.sh" \
  Release "$F2_REPRO_ROOT/release-build"

for F2_RUN in 1 2 3; do
  f2_historical_bash \
    "$F2_TOOLING_WORKTREE/Scripts/capture-editor-find-f2-authoritative-run.sh" \
    Debug "$F2_SOURCE_WORKTREE" "$F2_REPRO_ROOT/debug-build" \
    "$F2_REPRO_ROOT/debug-${F2_RUN}"
done

for F2_RUN in 1 2 3; do
  f2_historical_bash \
    "$F2_TOOLING_WORKTREE/Scripts/capture-editor-find-f2-authoritative-run.sh" \
    Release "$F2_SOURCE_WORKTREE" "$F2_REPRO_ROOT/release-build" \
    "$F2_REPRO_ROOT/release-${F2_RUN}"
done

/usr/bin/env -i \
  DEVELOPER_DIR="$F2_DEVELOPER_DIR" HOME="$F2_ACCOUNT_HOME" \
  LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 LOGNAME="$F2_ACCOUNT_NAME" \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR=/private/tmp USER="$F2_ACCOUNT_NAME" \
  /usr/bin/python3 -I \
  "$F2_TOOLING_WORKTREE/Scripts/build-editor-find-f2-retained-pack.py" \
  --pack-root "$F2_REPRO_ROOT/retained-pack" \
  --artifact-root "$F2_REPRO_ROOT/full-artifacts" \
  --run debug-1="$F2_REPRO_ROOT/debug-1" \
  --run debug-2="$F2_REPRO_ROOT/debug-2" \
  --run debug-3="$F2_REPRO_ROOT/debug-3" \
  --run release-1="$F2_REPRO_ROOT/release-1" \
  --run release-2="$F2_REPRO_ROOT/release-2" \
  --run release-3="$F2_REPRO_ROOT/release-3"

/usr/bin/python3 -I \
  "$F2_TOOLING_WORKTREE/Scripts/check-editor-find-f2-retained-evidence.py" \
  "$F2_REPRO_ROOT/retained-pack" --allow-partial
/usr/bin/python3 -I \
  "$F2_TOOLING_WORKTREE/Scripts/check-editor-find-f2-retained-evidence.py" \
  "$F2_REPRO_ROOT/retained-pack" \
  --artifact-root "$F2_REPRO_ROOT/full-artifacts"

"$F2_REPOSITORY_ROOT/Scripts/check-editor-find-f2-retained-evidence.py" \
  "$F2_REPRO_ROOT/retained-pack" \
  --artifact-root "$F2_REPRO_ROOT/full-artifacts"
```

These commands intentionally execute the immutable historical helpers; they do not claim the
current refactor produced a rerun. The empty outer environment and `bash -p` remove ambient
`BASH_ENV`, inherited functions, and user PATH authority, while `python3 -I` isolates the two
historical Python operator entry points. This cannot retrofit isolation into every Python process
spawned internally by the immutable shell bytes; the clean detached/current-UID-owned worktrees,
fixed system paths, and exact hashes above are the historical mechanism's explicit boundary.

The historical capture and builder refuse reused destinations, symlinks, non-owner inputs,
path/case collisions, source/build/hash mismatches, target processes that the historical classifier
reported at retained boundary checks or periodic samples, non-AC power, or thermal warnings. That
classifier exempted every exact frozen-host path during the runner interval, so its zero-match
records cannot exclude a duplicate or unrelated same-path host. The current maintained classifier
correlates a single host by the runner's dedicated process group, rejects duplicate/unrelated
same-path hosts, and cleanup signals only that process group; none of this is
retroactive evidence for the historical runs. The old monitor used a configured 200 ms sleep after
each scan; scan time makes this neither a 200 ms cadence nor continuous-absence proof.
The builder retains full artifacts by exact hash, deduplicates only identical shared inputs,
creates normalized summaries from private xcresult copies, and runs both audits before reporting
success. A reproduction is a new evidence set and must never silently replace or mix with the
versioned six-run compact pack.

The measured-source build/run helpers reject a dirty worktree, CI budget mode, reused output paths,
source/build mismatches, and post-run mutation. The build wrapper archives the exact commit, generates the
project inside a source snapshot, resolves packages once, seals the consumed source/package
inputs read-only, then uses `-disableAutomaticPackageResolution` for `build-for-testing`.
For the pre-generation tree digest, the maintained hasher treats the extraction container root as
a synthetic 0755 Git-tree root; this intentionally makes the wrapper's private 0700 directory
under `umask 077` agree with archive reconstruction. The builder and full auditor then compare
every archive member's kind, executable bits, and bytes against `sourceSnapshot`. The only
documented snapshot-only generated entries are the `Plainsong.xcodeproj` tree and
`App/Info.plist` and `App/Plainsong.entitlements` files, plus Xcode's empty
`Packages/*/.swiftpm/xcode`
directory chain for archived local packages; all other additions or missing or changed archived
members fail even if mutable build/provenance hashes are resealed.
`ENABLE_TESTABILITY=YES` is added only for Release because the reusable harness observes internal
EditorKit transition state; it does not enable `DEBUG` compilation or change the production
debounce.

Both builds have source-archive SHA-256
`f0b84f1b43145b443364b28666710166debcd0c0342dad6e90092c2c70e55506` and pre-generation
source-tree SHA-256
`51b3c5309d67603ac8a4f298deed795d3c4afa597f0ac83cfcc3632e0abfda94`.
The Debug/Release generated build-input hashes are respectively
`2093bf7df313cc13ae24c964a6661ae05d15471547c553fc295003bbebeba3b6` and
`3b8012362941b304eb7d7812a8b6e3c9196b49555060af8164db4dadbe4f1fb6`.
Both resolved-package-input hashes are
`ed48178719a6c72d2880d3972e900d3bbe51f180d13e01dffd452de936f779c3`.
That last digest deliberately covers the consumed checkout bytes (excluding checkout/submodule
`.git` administration), all artifact bytes, and `workspace-state.json`; mutable top-level bare
repository caches are not treated as source provenance. Unknown top-level entries fail closed.
The Debug/Release build-manifest hashes are
`fe374662a09ccb452ce55f0796740c96b66624483afe55aa53fcff2c8dfb3510` and
`5ca8c353ad557267745566ec597ba5971b024afb2796237158b062e3fcdd6a8a`.

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
| Debug 1 | `[225.510, 233.913, 228.660]`; **228.660** | `[235.019, 240.331, 245.017]`; **240.331** | `[602.360, 630.569, 599.486]`; **602.360** |
| Debug 2 | `[225.879, 254.087, 239.759]`; **239.759** | `[261.634, 247.120, 238.273]`; **247.120** | `[589.766, 582.622, 595.543]`; **589.766** |
| Debug 3 | `[238.206, 223.878, 254.123]`; **238.206** | `[233.184, 268.060, 255.494]`; **255.494** | `[600.940, 585.915, 608.818]`; **600.940** |
| Release 1 | `[174.740, 175.865, 177.079]`; **175.865** | `[187.643, 187.466, 185.949]`; **187.466** | `[240.922, 216.404, 256.174]`; **240.922** |
| Release 2 | `[171.491, 181.598, 178.105]`; **178.105** | `[182.054, 200.184, 184.481]`; **184.481** | `[231.986, 215.828, 257.420]`; **231.986** |
| Release 3 | `[178.451, 171.086, 173.628]`; **173.628** | `[187.924, 191.544, 185.269]`; **187.924** | `[220.235, 220.595, 232.867]`; **220.595** |

### Raw production-hosted edit results

All values are milliseconds. Bold values are the five-sample median; the last value in the receipt
cell is the diagnostic maximum. Budgets apply to each run's median, not its maximum.

| Configuration / run | Admission samples; median | Root state-update receipt samples; median; maximum |
|---|---|---|
| Debug 1 | `[1.150, 1.027, 16.620, 1.152, 1.025]`; **1.150** | `[4.811, 3.664, 19.917, 4.126, 3.981]`; **4.126**; max **19.917** |
| Debug 2 | `[1.212, 1.109, 15.871, 1.037, 0.973]`; **1.109** | `[4.975, 4.035, 18.488, 3.718, 3.842]`; **4.035**; max **18.488** |
| Debug 3 | `[1.159, 1.036, 16.001, 1.019, 0.976]`; **1.036** | `[4.799, 3.533, 18.990, 3.467, 3.618]`; **3.618**; max **18.990** |
| Release 1 | `[1.306, 0.869, 13.346, 1.079, 0.896]`; **1.079** | `[4.912, 3.234, 15.666, 3.900, 3.361]`; **3.900**; max **15.666** |
| Release 2 | `[1.117, 0.944, 13.367, 0.921, 0.909]`; **0.944** | `[4.582, 3.410, 16.106, 3.320, 3.419]`; **3.419**; max **16.106** |
| Release 3 | `[1.136, 0.930, 13.701, 0.888, 0.839]`; **0.930** | `[4.918, 3.281, 16.407, 3.465, 3.171]`; **3.465**; max **16.407** |

### Budgets and enforcement

The five round ceilings were already present in measured commit `c871ddf` before the
authoritative sequence. They were derived from earlier Debug measurements, remain defensible
against this final same-source rerun, and were not widened after any retained result. Release is
confirmation only and did not justify a threshold.

| Metric | Debug run medians | Debug median of run medians | Release run medians | Release median of run medians | Budget | Budget / slowest Debug run median |
|---|---|---:|---|---:|---:|---:|
| Zero query completion | 228.660, 239.759, 238.206 | **238.206** | 175.865, 178.105, 173.628 | **175.865** | < 400 ms | 1.67x |
| Sparse query completion | 240.331, 247.120, 255.494 | **247.120** | 187.466, 184.481, 187.924 | **187.466** | < 400 ms | 1.57x |
| Dense-truncated query completion | 602.360, 589.766, 600.940 | **600.940** | 240.922, 231.986, 220.595 | **231.986** | < 1,100 ms | 1.83x |
| Native edit admission | 1.150, 1.109, 1.036 | **1.109** | 1.079, 0.944, 0.930 | **0.944** | < 5 ms | 4.35x |
| Root state-update receipt | 4.126, 4.035, 3.618 | **4.035** | 3.900, 3.419, 3.465 | **3.465** | < 15 ms | 3.64x |

Query gates enforce each run's three-sample median. The production-hosted gates enforce each run's
five-sample admission and receipt medians. Deterministic fixture identity, endpoints,
count/truncation, session invalidation, transition generation, and off-main assertions remain hard
everywhere. Wall-clock thresholds are hard locally and print informational failures on hosted CI
under R15.

### Retained cold-path tail samples

All six retained runs have a larger synchronous sample at exactly the third insertion: Debug
admission is 15.871–16.620 ms and Release admission is 13.346–13.701 ms. The corresponding
receipt samples are 18.488–19.917 ms in Debug and 15.666–16.407 ms in Release. No sample is
discarded; the complete arrays above retain both the slow and non-slow shapes.

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
| Debug 1 | `ef9d4898-ec6d-462e-a00e-372d9ac8370a` | pre 3; measured 0; post 0 |
| Debug 2 | `6292d0a5-dab2-4180-a1df-69d19754323c` | pre 3; measured 0; post 0 |
| Debug 3 | `c4a4a9c6-6f22-42b0-90a7-324cab6bcb0c` | pre 3; measured 0; post 0 |
| Release 1 | `a4f1fb48-efe6-417c-8f5a-a6b645ce4d6e` | pre 3; measured 0; post 0 |
| Release 2 | `d49f668f-4a51-46ae-8efc-37ee25e973f6` | pre 3; measured 0; post 0 |
| Release 3 | `9ff731a8-5bc9-4449-b715-e25c0587577c` | pre 3; measured 0; post 0 |

The measured-source runner invokes `Scripts/check-editor-find-f2-warning-phase.py` before the
outer capture can accept a run, and the retained-pack auditor independently replays the same
warning-phase and negative-control contracts from each sealed raw log. The checks verify the
sealed raw-log and raw-result digests, exactly one ordered marker pair with the same UUID and
`edits=5`, exactly three known warnings before `BEGIN`, zero known warnings between `BEGIN` and
`END`, zero after `END`, zero other SwiftUI diagnostics, and two `local-hard` budget markers. It
also requires the `.xcresult` inspection copy to report exactly two passing tests, zero failures,
and exactly one coalesced Runtime Warning issue with the known message. Thus the raw log, rather
than coalesced issue count, is authoritative for warning phase.

For every retained run, the auditor moves one known pre-measure warning inside the measured interval
in memory and requires validation to fail specifically because a warning occurred during the five
edits. This proves a measured warning cannot pass merely because `.xcresult` still exposes the same
single coalesced issue; no mutated negative-control artifact is retained.

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

### Open boundaries

Measured commit `c871ddf` has no production highlight-all apply/clear implementation, so this F2
evidence records no F8 preservation, apply-latency, or clear-latency claim; later F8 work must carry
its own evidence. The harness begins at programmatic insertion and stops at root update receipt, so
full keystroke-to-screen remains open. F9 launched-app/physical-input acceptance is also outside
this pack, and no combined-tip result is claimed. These four boundaries are encoded as `open` in
the immutable retained manifest. The maintained auditor also prints the current policy boundary
`independent-durable-retention` and `historical-uncorrelated-target-process` as open without
rewriting that historical manifest; both compact and full audits therefore report all six open
boundaries.

## MarkdownCore Whole-Word Boundary Cost

Investigation of an intermittent local failure in
`TextSearchResourceBoundTests.testOneMegabyteContinuousUnicodeWordSkipsRejectedCandidatesLinearly`,
whose 3.0 s budget sat at roughly 1.2x headroom on a quiet machine and was exceeded outright once
the machine was busy. Per risk R15 that budget is hard locally, so it failed for every contributor
rather than only on CI.

| Field | Value |
|---|---|
| Date | 2026-07-29 |
| Branch | `phase3-text-search-word-boundary-cost`, branched from `main` at `dbc341c` |
| Measured commit | `4b1c836` — the commit holding the measured source. The commit stamping this section is its direct child and changes only documentation; no Swift source differs between them. |
| macOS | 27.0 (build 26A5388g), Darwin 27.0.0 |
| Machine | Apple M1 Pro, arm64, 16 GB RAM |
| Toolchain | Apple Swift 6.4 (swiftlang-6.4.0.20.104) |
| Budget | Unchanged at 3.0 s. No budget in this repository was widened by this work. |

### Reproduction

The budget is gated against Debug because `make test` runs `swift test` in Debug. Run from
`Packages/MarkdownCore`; build once so no compile lands inside a sample:

```bash
swift build --build-tests && swift test --filter TextSearchResourceBoundTests
```

Three scenarios were measured separately, because the failure was scenario-dependent: the test
alone (`--filter …/testOneMegabyte…`), its class (`--filter TextSearchResourceBoundTests`, where it
runs eighth of nine), and the whole package (`swift test`). Durations are the value the test
itself measures with `ContinuousClock` around `TextSearchEngine.matches`, which excludes fixture
construction. They were read by temporarily making `assertTextSearchDurationUnderLocally` print
on every call; that print is not part of the committed change.

### Measurements

Debug, seconds, against the unchanged 3.0 s budget:

| Scenario | Before (`dbc341c`) | After | Worst-case headroom after |
|---|---|---|---|
| Test alone | 2.246, 2.280, 2.255, 2.284 | 0.929, 0.916, 0.932, 0.920, 0.913 | 3.2x |
| Its class | 2.250, 2.230, 2.247, 2.278 | 0.904, 0.905, 0.909, 0.908 | 3.3x |
| Whole package | 2.530, 2.524, 2.547, 2.507 | 0.905, 0.908, 0.905, 0.917, 0.903 | 3.3x |

Release, class scenario, seconds: before 0.948, 0.973, 0.953; after 0.645, 0.638, 0.637.

The before/after pairs above were taken back to back in one session, stashing only the production
file, so they share machine state. Earlier in the same session, with the machine busier, the same
`dbc341c` source measured 7.050, 4.995, 4.854, 3.154, 2.924, 2.780, 2.864, 3.009 alone and 5.731,
7.143, 8.409, 5.329 in its class — four of those twelve are over budget, and the class scenario was
consistently the worst. That spread across identical source is the finding: the budget had no room
for ordinary machine-state variance. After the change the same scenarios sit in a 0.903-0.932 band,
about 3%, and the class scenario is no longer the worst case.

The whole MarkdownCore package suite also dropped from 12.6 s to 5.3 s, because five other tests in
the file exercise the same path.

### Where the time went

Profiled at 1 MiB of U+00E9 with a whole-word, case-sensitive `é` query. Whole-word rejection walks
every composed character once, so each row below is about one million operations. Standalone
microbenchmarks, Debug:

| Component | Cost |
|---|---|
| `rangeOfComposedCharacterSequence` | 0.55 s |
| `substring(with:)` + `generalCategory` | 0.84 s |
| — `generalCategory` alone | 0.15 s |
| `character(at:)` | 0.22 s |
| Whole engine call | 3.00 s |

Two costs were avoidable and neither is inherent to the fixture:

1. `isWordCharacter(in:storage:)` allocated a `String` per composed character purely to ask whether
   it is a word character — about 0.69 s of the 0.84 s row above.
2. The composed-sequence cache ran `append` + `removeFirst` on an eight-element `Array` on every
   miss, and in a marching scan every character is a miss. Stubbing the retention bookkeeping out
   entirely as a throwaway measurement took the engine call from 1.79 s to 0.80 s, which located
   roughly a second of overhead in cache maintenance rather than in the search itself.

### What changed

Three semantics-preserving changes in `TextSearchComposedSequences.swift`, all verified by
mutation testing (see below):

1. `isWordCharacter(in:storage:)` decodes UTF-16 out of the storage directly instead of
   materializing a substring, decoding surrogate pairs by hand. A range that splits a pair yields
   U+FFFD from `substring(with:)`, which is not a word scalar, so skipping the unpaired unit
   reaches the same answer.
2. `isWordScalar` answers ASCII without an ICU general-category lookup. This does not help the
   non-ASCII fixture above; it helps ordinary Markdown.
3. The composed-range cache became a fixed-capacity ring that overwrites its oldest slot, plus a
   retained most-recent range that serves marching scans in one bounds check. Composed sequences
   partition the storage, so at most one retained range can contain a location and retention order
   affects hit rate only, never the answer.

### Falsifiability

The new `TextSearchWordBoundaryScalarTests` were mutation-tested against the production file:

| Mutation | Result |
|---|---|
| Surrogate decode shift 10 → 9 | 6 failures |
| ASCII digit range off by one (admits `:`) | 1 failure |
| ASCII lowercase range off by one (drops `a`) | 1 failure |
| Ring never advances its eviction slot | 1 failure |
| Most-recent range returned without its containment check | Non-terminating; killed at 10 minutes |
| Ring lookup scans unused slots | No failure — see below |

The last one is a genuine no-op rather than a coverage gap: unused slots hold
`NSRange(location: NSNotFound, length: 0)`, whose zero length means the containment test can never
succeed, so scanning them is wasted work and nothing more.

One coverage gap was found this way and closed. The first ASCII test compared the new decoding
against the substring-based `isWordCharacter(in: String)` overload, but both call the same
`isWordScalar`, so the shared ASCII shortcut inside it was invisible to that comparison — the
off-by-one mutation passed. `testEveryASCIIScalarAgreesWithTheGeneralCategoryRule` restates the
general-category rule as an independent oracle over all 128 ASCII scalars, and catches it.

### WS4B cross-check

The changed code is the whole-word path the frozen WS4B probes exercise, so those were measured
head to head rather than assumed unaffected. Debug medians, source reverted to `dbc341c` and
restored in place between runs, both through the full `xcodebuild ... test` stage so the runs share
load:

| WS4B probe | Baseline | After | Budget |
|---|---|---|---|
| dense whole-word rejection, `unicode-periodic` | 1154.951 ms | 669.050 ms | 2500 ms |
| workspace search, 2,000 files, smart case | 1101.226 ms | 1042.827 ms | 3000 ms |
| workspace search, 2,000 files | 1075.330 ms | 1067.072 ms | 3000 ms |
| dense whole-word rejection, `ascii-suffix` | 45.298 ms | 45.685 ms | 200 ms |
| admitted 512 KiB file | 37.532 ms | 39.307 ms | 150 ms |
| admitted 512 KiB CJK file, smart case | 24.735 ms | 25.211 ms | 150 ms |
| cancel-to-drain | 0.170 ms | 0.147 ms | 50 ms |

All 14 WS4B probes pass in both configurations. `unicode-periodic` improves 42%; everything else is
within run-to-run noise and nothing regressed. That probe is the one the 2026-07-26 Decision Log row
recorded as effectively at parity with its budget on a cold first Debug run, so the extra room is
worth having. **No WS4B budget is changed by this work** — those numbers stay frozen where PR #94
and its follow-ups set them, and re-freezing them against these faster medians would be a separate
decision with its own evidence.

### Full `make test` status

`make test` fails at this branch tip, and fails identically at `dbc341c`, on two tests:
`PlainsongUITests.WorkspaceSearchAcceptanceTests.testClickThenArrowKeysUseSearchSelection` and
`…testShortcutKeyboardActivationAndEscapeTransitions`, both with
`Failed to activate application 'app.plainsong.editor' (current state: Running Background)`. These
are XCUITests that require the app to become frontmost, which a non-interactive session cannot
grant. This was verified by running the same `xcodebuild ... test` stage with only
`TextSearchComposedSequences.swift` reverted to `dbc341c`, not inferred from the failure text.

One earlier full-`make test` run at this tip did report three WS4B budget failures. That run
overlapped with `make lint`/`make format` on the same machine and is a contention artifact, not a
result: in it the unrelated `admitted 512 KiB` probe read 569.012 ms against the 39.307 ms it
measures when the run has the machine to itself, a 14x slowdown no code change explains. It is
recorded here because it is the same measurement hazard this whole section is about — WS4B budgets
are only meaningful from the dedicated `-only-testing` commands documented above, not from a
loaded `make test`.

### Notes

- The three options weighed in the brief resolved as follows. A one-per-process warm-up in the
  shape of `WorkspaceSearchPerformanceWarmUp` was measured and rejected: this test runs eighth of
  nine in its class and last-but-one in the package, so it already had ample warm-up, and the
  class scenario was reliably *slower* than running it alone — the opposite of a cold-start
  signature. Avoidable work was the actual cause. Re-freezing the budget number was never reached.
- The fixture shape was left alone. Its 1 MiB continuous-word text is what makes the linear-skip
  assertion meaningful, and its instrumentation bounds
  (`literalCandidatesExamined == 1`, `uncachedComposedUTF16UnitsVisited <= length + 2`) are
  unchanged and still pass, so the test still gates the same property it always did.
- Same-session before/after pairs are what the comparison rests on. Absolute numbers from
  different sessions are not comparable here: identical `dbc341c` source measured 2.25 s and 8.41 s
  in the same scenario a few hours apart.

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
