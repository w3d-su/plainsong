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
| Current `Scripts/editor-find-f2-tooling.sha256` | `c448303f9f5b2f89169564aed76af3c8b5e8387015385fac3fd62b40958e8b28` |
| Current inventory verifier | `047aca8f71e33ff6907f447546111eecbbb0bdea391ad98b2d1681c0ac4edb0c` |
| Current isolated bootstrap | `b67dac167543c83b0c8c4e1844dbe2421c1d16a6bcff301603bf2c3ac0bfa59d` |
| Current capture schema | `156177ae6c047e7f1295381c557c440263dcac63d48a3fbaf01dd69d4bcb3d56` |
| Current auditor / builder entry points | `ed9ad47f21d6a4df4ae1dc24a76c669e9eac11548fbdcab1bd0a49722cf3a9f2` / `6cab5471e11f06cb9b853a54c209fd9f87279330975da696a74c33c5094b3b4f` |
| Current capture / runner / build entry points | `7531e3bbc81b264125c98341a61f4a38f48bb2e358385cce4cd5ce7b3652ff2f` / `0d220849377cd21d11207ebd35056b7ce9a21f93df23592945fd9ee5bcd169c5` / `9c54513d118bf150d52aa8f781933df98fc2141959c988e67dcf42718cd9e6a2` |

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
  c448303f9f5b2f89169564aed76af3c8b5e8387015385fac3fd62b40958e8b28
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
  c448303f9f5b2f89169564aed76af3c8b5e8387015385fac3fd62b40958e8b28
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

## Export E9 informational bridge receipt — 2026-09-18

PR #115 review-fix probe:
`ExportHTMLBridgeDecodingTests.testMultiMegabyteReadyBridgeReceiptFitsExistingMainActorBudget`.
Run with `swift test --package-path Packages/PreviewKit --filter ExportHTMLBridgeDecodingTests`.
Environment: macOS 27.0 (26A428), Apple Swift 6.4, arm64, Debug.

The probe creates a Foundation `NSDictionary`/`NSString` message containing **6,250,000
UTF-8 bytes**, installs a finalization-phase pending request, and times the production
`receiveBridgeBody` routing, direct typed-field validation, and continuation resolution
on the main actor. Five Debug samples from the local 2026-09-18 worktree run were
**0.049375 / 0.005792 / 0.003834 / 0.003541 / 0.003375 ms** (maximum **0.049375 ms**).
Payload construction and subsequent full-content equality assertions are outside the
measured interval. Every sample checks exact content, request correlation, and pending
state removal. No JSON encoding/decoding or full HTML scan occurs inside receipt.

The existing 16 ms main-actor bound is asserted locally and informational when `CI=true`;
no new export budget is frozen. This is a synthetic bridge-body receipt measurement,
not WebKit IPC/string construction, complete offscreen export, image/font readiness,
physical keystroke-to-screen, concurrent typing, or Debug/Release end-to-end evidence.
**E9 remains open** for PR G. The full export payload limit and resource-policy gates
remain separately owned by PR D/G.

## Math-Dense Preview Render (informational, 2026-09-21)

- Fixture: `Fixtures/math-dense-100kb.md` — 100,156 bytes at measurement
  (100,155 bytes after removing one trailing blank line before commit); remark-AST count:
  292 `$$`/`aligned`/`pmatrix` display blocks + 292 ` ```math ` fences
  + 1,168 inline `$…$` formulas = 1,752 formulas total.
- Procedure: `preview-src/test/math-perf.test.ts` — vitest/JSDOM pipeline render,
  one warmup + three samples per pipeline, median reported.
- Environment: Node v24.16.0, vitest 4.1.8, Apple M-series arm64, macOS 27.
- Measured value: Markdown median 937.178 ms, samples `[875.318, 937.178, 1200.392]`;
  MDX median 940.342 ms, samples `[956.188, 940.342, 887.465]`.
- Baseline comparison (2026-09-21 review probe, same machine/Node/fixture, one
  warmup + three samples): pre-change `HEAD` pipeline medians were
  910.39 ms (Markdown) / 954.16 ms (MDX) vs 837.86 ms / 824.85 ms after the math
  wrapper changes — the ~1 s magnitude predates this work and is not a regression
  introduced by it. Order-fixed, low-sample, Node-only: directional evidence, not
  a speedup claim.
- Result: **Over budget (recorded, not relaxed).** The 100 ms/100 KB preview budget is
  measured in WebKit as a settled-update gate by `PerformanceTests`; this Node/JSDOM
  number is informational, not the WebKit gate. It is roughly 10x the general-document
  median at this formula density; whether KaTeX CPU dominates is an unverified
  hypothesis — a segmented measurement or profile would be required to attribute it.
  Real WebKit acceptance for math-dense documents remains open; no budget was changed and
  no caching layer was added (measure first, cache only with evidence).

## Export PR D cap fixtures — 2026-09-28

Debug `swift test --package-path Packages/PreviewKit --filter ExportResourceResolverTests`
on this worktree. The 32 MiB case is
`testDistinctRasterBytesStopAtThirtyTwoMebibytesAndOneExtraByteOmits`. Fixture bytes are
generated in the test and are not committed. The timed interval is only
`ExportResourceResolver.resolve` after the files exist.

| Measurement | Value |
|---|---|
| Resolve elapsed | 0.053862 s |
| Host RSS before resolve | 70,090,752 bytes (70.1 MB) |
| Host RSS after both resolves | 179,912,704 bytes (179.9 MB) |
| 10 MiB boundary test, including PNG padding and disk write | 9.551 s, passed |
| Repeated-reference test, including disk write | 22.138 s on the rerun, passed |

The RSS delta covers two in-memory results: one exact 32 MiB embed set and one 30 MiB
embed set whose next image is omitted. Base64 expansion of those rasters accounts for
most of the growth. A later full PreviewKit suite run on the same machine measured the
same resolver interval at 0.061 s, with host RSS 101.2 MB before and 221.6 MB after,
because earlier tests had already allocated. No export wall-clock budget is frozen.
Typing latency is unchanged because export runs only from `PreviewController.exportHTML`,
off the editor keystroke path. E9's broader Debug/Release matrix remains open.

## Export PR D review fixes — 2026-09-29

Debug `swift test --package-path Packages/PreviewKit` on this worktree. Resolver
acceptance now requires an ImageIO thumbnail decode (at most 16 px) in addition to the
type sniff, and a repeated reference reuses the first decision instead of re-reading
the file.

| Measurement | Value |
|---|---|
| 32 MiB cap fixture, `ExportResourceResolver.resolve` only, isolated filter | 0.061 s |
| Host RSS before / after both resolves (same run) | 67,059,712 / 178,700,288 bytes (67.1 / 178.7 MB) |
| Same interval inside the locked `ExportHTML\|ExportResourceResolver` filter | 0.053 s (RSS 141.7 → 221.8 MB after earlier tests) |
| Encoded finalization payload, 100 references to one 1 MiB PNG, PR head (v7) | 139,820,261 bytes |
| Same payload after protocol v8 `dataURIFrom` | below the asserted 1,423,726-byte bound (one 1,398,126-byte data URI plus at most 256 bytes per reference) |

The cap fixture's rasters are 1×1 PNGs padded to their exact byte size with a `tEXt`
chunk (`ExportRasterFixture.png(exactByteCount:)`), so the decode proof there decodes a
single pixel. Its unchanged interval (0.054 s recorded on 2026-09-28) therefore says
nothing about the decode proof's cost on a real 10 MiB photographic PNG or JPEG. That cost
is unmeasured and belongs to E9's large-document pass. The payload rows come from
`ExportResourceResolverReviewTests.testHundredReferencesToOneImageSerializeItsDataURIOnce`
run against the PR head sources and then against this change. No export wall-clock
budget is frozen, and export still runs only from `PreviewController.exportHTML`, off the
editor keystroke path.

## Replace PR F WYSIWYG single Replace — 2026-09-30

Apple M1 Pro (arm64), macOS 27.0 (26A428), Xcode 27.0 (27A5194q), Debug.
The exact reveal proof runs only on explicit Replace. After the 2026-10-01 review
fix and subsequent restack, `MarkdownEditorView` inherits the separate scheduling
bug-fix PR (#136, `phase3-editor-highlight-schedule-fix`), which bounds executing
highlight work and pending requests. Native writer/input, caret snapping,
selection-driven reveal, marked-text and native-edit styling guards remain unchanged. The only edit-path addition is an O(1)
record of the applied model, made once per *applied* debounced highlight in
`MarkdownTextView+HighlightApply.swift`, never per keystroke; the reveal proof reads it.

`EditorReplaceWYSIWYGPerformanceTests.testLargeFixtureWYSIWYGTypingWithAppliedReplaceSnapshotStaysUnderBudget`
passed in the complete EditorKit suite: 30 native insertions on `large-1mb.md`,
maximum **0.398583 ms** (review-fix rerun: **0.453542 ms**). This model-backed fixture
does not run the production SwiftUI/Find pipeline and is not App typing proof.

`EditorFindHostedGateTests.testHostedLargeFixtureWYSIWYGTypingWithReplaceFindSessionStaysUnderBudget`
mounts the production `WorkspaceWindow`, Experimental WYSIWYG and an open Find
session (`ordinary prose`), waits for initial styling/authorization, then inserts
30 characters with 20 ms between calls. Timing includes synchronous native
insertion, App publication and debounce scheduling; it excludes the async parse,
settled rendering and hardware event delivery. The functional fixture removes
Find's debounce, so this probe restores its **production 150 ms** default before
timing. Local `< 16 ms` assertions remain hard; hosted CI wall clocks are
informational under risk R15.

**The probe is opt-in** because its first-iteration maximum exceeded 16 ms in both
#131 and PR F (below), so a plain `make test` would flake; the budget is unchanged.
Without the variable it reports an `XCTSkip`. Run it on an idle machine, serialized
with any other Mac test run (`lockf` on the shared lock file if agents share the Mac):

```sh
lockf -k "$PLAINSONG_XCODEBUILD_LOCK" env TEST_RUNNER_PLAINSONG_RUN_HOSTED_TYPING_GATE=1 xcodebuild -project Plainsong.xcodeproj \
  -scheme Plainsong -configuration Debug test \
  -only-testing:PlainsongTests/EditorFindHostedGateTests/testHostedLargeFixtureWYSIWYGTypingStaysUnderBudget
```

xcodebuild forwards only `TEST_RUNNER_`-prefixed variables into the hosted test
process, where the prefix is stripped (the same mechanism as `make test`'s
`TEST_RUNNER_CI`). Raw samples are in the keep-always XCTest attachment and stdout.

Controlled comparison (2026-09-30): exact #131 product
`a0213857c69300931385b337369c0e7197cd8f3f` (only the identical hosted test/helper
added), three iterations first; then the PR F tree as it stood before review, three
iterations. **That PR F tree also restarted the highlight debounce with a directly
created `Task`; the review fix reverted it, so the row below does not measure the
final tree.** [Retained raw samples](evidence/editor-replace-r5-20260930-typing.json)
come from keep-always XCTest attachments.

| Product | Iteration 1 maximum | Iteration 2 maximum | Iteration 3 maximum | Hard-budget result |
|---|---:|---:|---:|---|
| #131 baseline | 23.599500 ms | 15.162750 ms | 15.375958 ms | 1 failure, 2 passes |
| PR F before review (`Task` scheduler, native-edit guard unchanged) | 24.359250 ms | 14.850583 ms | 15.258833 ms | 1 failure, 2 passes |

**The first iteration exceeds budget in both products; the budget is not relaxed.**
Later iterations pass in both. This ordered, low-sample comparison shows similar
steady measurements but does not establish a speedup or exclude smaller regressions;
first-iteration latency still needs profiling. It is not full keystroke-to-screen,
physical-keyboard or real-IME evidence and does not close R9.

Review-fix opt-in run (2026-10-01, 7598f28 `.task(id:)` tree, one iteration):
a plumbing check only,
taken at load averages of 21–27 from other agents' work on the shared Mac. Maximum
**19.044584 ms** (median 15.083 ms; the same bimodal ~0.8 ms / ~15 ms samples as
above), so it **failed** the hard budget. Contention makes this unusable as
evidence, and no baseline was rerun beside it. The final tree's typing path has not
been re-measured on an idle machine; the owner should run the command above before R9.

Diagnostic history: with the helper's zero Find debounce, baseline maxima were
30.008916 / 26.148167 / 23.394708 ms and an intermediate PR F tree measured
21.157208 / 17.900292 / 16.685042 ms, all failed. A trial allowing fresh WYSIWYG
styling while native editing was active measured 18.658417 / 18.299334 /
18.608375 ms with production debounce (all failed), while restoring the existing
guard returned the normal slow samples to about 14.6 ms. That trial was removed;
no presentation-apply or typing-budget exception ships. The 18/18 hosted
post-write/Undo/Redo reparse executions reported before review used the `Task`
scheduler. Before restack, restoring `.task(id:)` allowed those automatic-reparse
methods to time out under load. The two recorded timeouts were attributed to the
dropped final request; the separate scheduling bug-fix PR now supplies the fix
(see its entry below).

Earlier complete EditorFind/EditorReplace hosted run (pre-review tree): **104/104
passed**, including the hard local typing probe (maximum **15.009834 ms**; raw
samples in the linked JSON). Review-fix runs (2026-10-01): full MarkdownCore
303/303; full EditorKit 405 tests, seven real-IME opt-in skips, zero failures;
hosted EditorFind/EditorReplace classes plus the nine App WYSIWYG policy tests: 114
executed, 111 passed, the typing probe skipped (opt-in), and two failed
(`testHostedReplaceFoldedDelimiterThroughDispatcherAndAutomaticReparseUndoRedo` and
`testHostedReplaceImageThroughDispatcherAndAutomaticThumbnailUndoRedo`, both
automatic-reparse timeouts at load averages of about 14–16).

## Editor highlight scheduling fix — 2026-10-01

Apple M1 Pro (arm64), macOS 27.0 (26A428), Xcode 27.0 (27A5194q), Debug, on a Mac shared
with other agents' builds and tests (load averages recorded per run). `MarkdownEditorView`
now restarts its 20 ms debounced visible-range highlight through `EditorHighlightScheduler`
instead of SwiftUI `.task(id:)` (Decision Log 2026-10-01). Per keystroke the view still
bumps `@State highlightRevision` and `body` still reads it, so the SwiftUI update cadence
is unchanged. Each schedule replaces one pending operation and cancels the executing
request; a single runner waits for it to return before creating the latest highlight task.
The debounce, parser, apply guards and IME behavior are unchanged.

**Dropped-request reproduction (opt-in, not deterministic).**
`EditorFindHostedGateTests.testHostedHighlightScheduleStressAppliesAfterEveryEdit` opens
`Intro **文字😀** tail` in Experimental WYSIWYG, then runs 15 cycles of edit / Undo / Redo
/ Undo. It counts an edit as dropped when no highlight applies within 3 s. Set
`PLAINSONG_XCODEBUILD_LOCK` to the shared lock used by the other agents, then run:

```sh
lockf -k "$PLAINSONG_XCODEBUILD_LOCK" env TEST_RUNNER_PLAINSONG_RUN_HIGHLIGHT_SCHEDULE_STRESS=1 xcodebuild -project Plainsong.xcodeproj \
  -scheme Plainsong -configuration Debug test \
  -only-testing:PlainsongTests/EditorFindHostedGateTests/testHostedHighlightScheduleStressAppliesAfterEveryEdit
```

| Run order | Product | Load average (1 min, start → end) | Edits without an applied highlight |
|---:|---|---|---:|
| 1 | d2f739a, `.task(id:)` (untracked copy of the probe) | 52.68 → 22.64 | 10 / 60 |
| 2 | this branch | 22.64 → 22.03 | 0 / 60 |
| 3 | this branch | 21.87 → 20.83 | 0 / 60 |
| 4 | d2f739a, `.task(id:)` | 20.83 → 13.69 | 8 / 60 |

Earlier, on the Replace PR F branch, the hosted folded-delimiter Replace test failed 8/15
iterations with `.task(id:)` and passed 15/15 with a direct `Task` (load averages
about 12–19). An in-memory trace of a failing iteration showed SwiftUI evaluating `body`
with the final `highlightRevision` at least five times without cancelling the in-flight
task or starting a new one, after which that task stopped at its revision guard. Passing
iterations show the same traced event order, so **the drop could not be forced
deterministically**. The rates depend on load, and the Replace PR F reviewer saw no failure
on a quieter machine. The deterministic contract is pinned instead by
`EditorHighlightSchedulerTests` (one apply of the final revision per burst; every superseded
request cancelled, including one already past its debounce).

**Initial typing diagnostic, superseded.** The earlier ABABAB measurements on d2f739a
used a scheduler that cancelled and immediately spawned each new task, without an open
Find session. They are retained in
[evidence/editor-highlight-schedule-20261001-typing-initial.json](evidence/editor-highlight-schedule-20261001-typing-initial.json)
for provenance only. They do not validate the final bounded scheduler or reproduce the
supplied Replace F Find-session measurement method.

**Final typing (§12, §17.8, opt-in).** Both trees mount the production `WorkspaceWindow`
on `Fixtures/large-1mb.md`, open Find for `ordinary prose`, restore its production 150 ms
debounce, and wait for styling and Replace authority to settle. The probes time 30
synchronous native `insertText` calls with 20 ms between them, in source-only and WYSIWYG.
Timing includes native input and App publication. The fix also runs `restart()` inside
the timed `insertText`, whereas main restarts `.task(id:)` outside this window; the
comparison is conservative against the fix. It excludes async parse/layout and hardware
event delivery. The baseline is refreshed origin/main e95ac36
(#132; initial work started on d2f739a/#131). Identical untracked probes are installed
only in the isolated baseline worktree. Every xcodebuild is serialized under the existing
shared `lockf` lock, with load averages sampled after acquiring it. Final ABABAB samples
are retained in [the raw JSON](evidence/editor-highlight-schedule-20261001-typing.json).
The 16 ms budget is unchanged.

| Run | Product | Load (1 / 5 / 15 min, start → end) | Source-only max / median (ms) | WYSIWYG max / median (ms) |
|---:|---|---|---:|---:|
| 1 | main e95ac36 | 18.99 / 15.29 / 11.16 → 15.17 / 14.72 / 11.10 | 17.364 / 14.771 | 16.275 / 14.892 |
| 2 | bounded scheduler | 15.17 / 14.72 / 11.10 → 13.65 / 14.36 / 11.11 | 15.572 / 14.868 | 15.414 / 14.684 |
| 3 | main e95ac36 | 13.65 / 14.36 / 11.11 → 12.18 / 13.95 / 11.07 | 16.289 / 14.713 | 15.532 / 14.703 |
| 4 | bounded scheduler | 12.18 / 13.95 / 11.07 → 12.51 / 13.86 / 11.12 | 17.274 / 15.054 | 15.808 / 14.776 |
| 5 | main e95ac36 | 12.51 / 13.86 / 11.12 → 11.41 / 13.46 / 11.07 | 20.506 / 14.839 | 15.235 / 14.666 |
| 6 | bounded scheduler | 11.41 / 13.46 / 11.07 → 10.46 / 13.03 / 11.00 | 15.668 / 14.825 | 15.209 / 14.744 |

The runs were interleaved ABABAB with identical probes. Both trees exceed the hard 16 ms
budget in some runs; sample distributions remain bimodal. The shared-machine loads and
three runs per product do not establish a speedup or exclude a regression. **Idle-machine
measurement pending**: the owner must rerun both opt-in modes before opening the PR.
These numbers are not keystroke-to-screen, hardware input or real-IME evidence.

**Final bounded-scheduler stress:** 0 drops / 60 edit–Undo–Redo–Undo operations, load
[19.25, 14.52, 11.67] → [17.5, 14.41, 11.7] (1 / 5 / 15 min). This is opt-in empirical evidence,
not a deterministic reproduction of the original SwiftUI drop.

EditorKit: 395 tests, 7 skips, zero failures.

MarkdownCore: 303 tests, 0 skips, zero failures.

hosted: 117 tests, 3 skips, zero failures.

`make build`, pinned SwiftFormat 0.62.1 `make lint` and `git diff --check` passed.
The scheduler contract suite has five deterministic tests; no production timing changed.

Historical follow-up: PR D rejection restore (`applyReconciledSource` → `textView.text =`)
removed presentation attributes until an unrelated reparse. Handoff 21's
[reconciled-source fix](#reconciled-source-presentation--2026-10-05) requests an automatic
fresh parse; the scheduler PR itself did not repair it.

## Replace PR F restack — 2026-10-01

Merge origin/main e95ac36 (#131 d2f739a plus #132) into Replace F using merge, preserving
main's authoritative nil-key-window override and the F WYSIWYG/asset helper. Then merge
`phase3-editor-highlight-schedule-fix`. No rebase, push or Find-controller changes.
The scheduler bug-fix PR owns the cancellation/coalescing implementation; F's automatic
presentation reparses now run on it. PR D's presentation-attribute reset on rejected
publication was a known follow-up in both changes; it is addressed separately by
[Handoff 21](#reconciled-source-presentation--2026-10-05).

Post-restack verification on the merged source tree: **EditorKit 411 tests**, seven
real-IME opt-in skips, zero failures; **hosted EditorFind/EditorReplace plus all nine
App WYSIWYG policies: 125 tests**, four stress/typing opt-in skips, zero failures.
`testHostedReplaceFoldedDelimiterThroughDispatcherAndAutomaticReparseUndoRedo` and
`testHostedReplaceImageThroughDispatcherAndAutomaticThumbnailUndoRedo` each passed **3/3**
using `-test-iterations 3`, with no failure retry. The complete hosted run also passed
both cases once. Repeated-run load (1 / 5 / 15 min):
[13.96, 14.4, 12.17] → [12.04, 13.93, 12.07].
`make build`, pinned SwiftFormat 0.62.1 `make lint`, and `git diff --check` passed.
[Verification record](evidence/editor-replace-f-restack-20261001.json).
The A/B typing samples above validate the scheduler dependency only to the stated limits:
idle-machine measurement is pending, the 16 ms gate remains unchanged, and R9/real IME
and batch Replace remain open.


## Highlight scheduler review follow-ups — 2026-10-02

The 20 ms debounce now starts before waiting for a cancelled parse; only parse/apply
is serialized. Deterministic tests cover this overlap, one in-flight parse, and a
queued viewport callback delivered after disappearance. The hosted stress probe also
compares the settled applied fold plan against current text and native selection.
EditorKit: 397 tests, seven opt-in skips, zero failures; the seven scheduler contract
tests passed. Hosted Find/Replace and WYSIWYG policy suite: 117 tests, three opt-in
skips, zero failures. Pinned SwiftFormat 0.62.1 lint and `git diff --check` passed.

No always-on test covers the SwiftUI wiring. Reverting the view to `.task(id:)` would
still pass `make test`; the hosted stress probe is opt-in empirical coverage.

**Idle measurement still pending.** The historical loaded A/B numbers above remain
loaded diagnostics. The final process gate requires 1-minute load below 3 and no
other xcodebuild holding the shared lock, checked before every batch. Run the retained
helper LAST, after both branches' functional validation:

```sh
export PLAINSONG_XCODEBUILD_LOCK=/private/tmp/plainsong-xcodebuild-test.lock
export PLAINSONG_BASELINE_ROOT=/private/tmp/plainsong-h22-baseline
export PLAINSONG_FIX_ROOT=/Users/davis._.su/Documents/plainsong-highlight-schedule-fix
export PLAINSONG_STACK_ROOT=/private/tmp/plainsong-replace-wysiwyg
# Refresh the clean baseline to the current fix/main merge base, then generate
# all three projects in their own worktrees before running the helper.
git -C "$PLAINSONG_BASELINE_ROOT" checkout --detach "$(git -C "$PLAINSONG_FIX_ROOT" merge-base HEAD origin/main)"
for root in "$PLAINSONG_BASELINE_ROOT" "$PLAINSONG_FIX_ROOT" "$PLAINSONG_STACK_ROOT"; do
  make -C "$root" generate
done
/usr/bin/python3 "$PLAINSONG_FIX_ROOT/docs/evidence/editor-highlight-schedule-20261002-idle.py"
```

The helper acquires the existing lock nonblockingly, samples `sysctl -n vm.loadavg`
inside it, refuses loaded batches, and waits at most five minutes for a qualifying
slot. It builds every product for testing and records the actual merge-base SHA of the isolated baseline, then runs main/fix/main/fix/main/fix,
followed separately by main/stack/main/stack/main/stack. Each batch uses:

```sh
env TEST_RUNNER_PLAINSONG_RUN_HOSTED_TYPING_GATE=1 xcodebuild \
  -project Plainsong.xcodeproj -scheme Plainsong -configuration Debug \
  -destination platform=macOS test-without-building \
  -only-testing:PlainsongTests/EditorFindHostedGateTests/testHostedLargeFixtureSourceOnlyTypingStaysUnderBudget \
  -only-testing:PlainsongTests/EditorFindHostedGateTests/testHostedLargeFixtureWYSIWYGTypingStaysUnderBudget
```

Run from `/private/tmp/plainsong-highlight-baseline`,
`/Users/davis._.su/Documents/plainsong-highlight-schedule-fix`, or
`/private/tmp/plainsong-replace-wysiwyg` as indicated by the interleaving. Both opt-in
modes keep the production 150 ms Find debounce and the hard 16 ms local budget.
No loaded numbers are recorded as idle evidence.


## Replace PR F review follow-ups — 2026-10-02

Merged the updated highlight scheduler branch (`fff481cc98de1edeb7adb0b9e459de780ba8c88b`)
with local merge `d8305c3251cab0d8ed991e3d658315c0238b2cab`. The nested-bold link
regression refuses all seven hidden chrome pieces with zero writer activations, and
commits when the link chrome is revealed. The retained bug-fix typing probe and one
`makeHostedEditorWorkspace` helper replace the duplicate probe and workspace helper;
the opt-in environment variable is unchanged. The 7598f28 typing run above is now
labelled with its measured `.task(id:)` tree. Historical timeouts are attributed to
the observed dropped request; no deterministic reproduction is claimed.

Verification: full EditorKit **415 tests**, seven real-IME opt-in skips, zero failures;
hosted EditorFind/EditorReplace plus all nine WYSIWYG policies **124 tests**, two typing
opt-in skips, zero failures. The enhanced highlight stress probe was enabled in the
hosted run: **0 drops / 60 edits**, including settled fold-plan checks. Both historical
automatic-reparse timeout methods passed **3/3**, six executions total, without failure
retry. `make build`, pinned SwiftFormat 0.62.1 lint, and `git diff --check` passed.

**Idle measurement still pending.** No new typing numbers were recorded during these
functional checks. Use the fully configured helper command below
LAST to compare the committed bug-fix head and, separately, the committed stacked F
head against the current fix/main merge-base baseline. Exact batch commands and the strict load/lock gate
are retained in the highlight-scheduler review entry above. R9, real IME and batch
Replace remain open. The scheduler fix is cited as #136.


## Handoff 22 idle admission — 2026-10-04 (PR #136)

**Idle measurement still pending.** Five-minute admission refused every batch;
no build or typing probe ran, and no performance samples were recorded. The actual
candidate product SHA is `2530c02ea1bf0205525c6477e881842c3d258616`; the clean baseline SHA is `4cef0ccf44e422ad22ab34c4319a46c42e69b009`.
The former baseline contains an untracked test file, so a separate clean worktree
`/private/tmp/plainsong-h22-baseline` was prepared without using that file.
Raw admission output: `docs/evidence/h22-idle-admission.log`; structured status:
`docs/evidence/handoff22-20261004-admission.json`. All historical loaded A/B values
remain diagnostics, with no pass/fail or regression conclusion for this head.
The hard 16 ms typing budget is unchanged. Owner heavy-app/agent shutdown was
requested before admission. No owner-only gates are closed.

Reproduce on an idle machine after fetching/merging main (then remeasure):

```sh
export PLAINSONG_XCODEBUILD_LOCK=/private/tmp/plainsong-xcodebuild-test.lock
export PLAINSONG_BASELINE_ROOT=/private/tmp/plainsong-h22-baseline
export PLAINSONG_FIX_ROOT=/Users/davis._.su/Documents/plainsong-highlight-schedule-fix
export PLAINSONG_STACK_ROOT=/private/tmp/plainsong-replace-wysiwyg
# Refresh the clean baseline to the current fix/main merge base, then generate
# all three projects in their own worktrees before running the helper.
git -C "$PLAINSONG_BASELINE_ROOT" checkout --detach "$(git -C "$PLAINSONG_FIX_ROOT" merge-base HEAD origin/main)"
for root in "$PLAINSONG_BASELINE_ROOT" "$PLAINSONG_FIX_ROOT" "$PLAINSONG_STACK_ROOT"; do
  make -C "$root" generate
done
/usr/bin/python3 "$PLAINSONG_FIX_ROOT/docs/evidence/editor-highlight-schedule-20261002-idle.py"
```


## Handoff 22 idle admission — 2026-10-04 (PR #137)

**Idle measurement still pending.** Five-minute admission refused every batch;
no build or typing probe ran, and no performance samples were recorded. The actual
candidate product SHA is `e76b87530e5f018498abe8d2b3638f030ee7b1b4`; the clean baseline SHA is `4cef0ccf44e422ad22ab34c4319a46c42e69b009`.
The former baseline contains an untracked test file, so a separate clean worktree
`/private/tmp/plainsong-h22-baseline` was prepared without using that file.
Raw admission output: `docs/evidence/h22-idle-admission.log`; structured status:
`docs/evidence/handoff22-pr137-20261004-admission.json`. All historical loaded A/B values
remain diagnostics, with no pass/fail or regression conclusion for this head.
The hard 16 ms typing budget is unchanged. Owner heavy-app/agent shutdown was
requested before admission. No owner-only gates are closed.

Reproduce on an idle machine after fetching/merging main (then remeasure):

```sh
export PLAINSONG_XCODEBUILD_LOCK=/private/tmp/plainsong-xcodebuild-test.lock
export PLAINSONG_BASELINE_ROOT=/private/tmp/plainsong-h22-baseline
export PLAINSONG_FIX_ROOT=/Users/davis._.su/Documents/plainsong-highlight-schedule-fix
export PLAINSONG_STACK_ROOT=/private/tmp/plainsong-replace-wysiwyg
# Refresh the clean baseline to the current fix/main merge base, then generate
# all three projects in their own worktrees before running the helper.
git -C "$PLAINSONG_BASELINE_ROOT" checkout --detach "$(git -C "$PLAINSONG_FIX_ROOT" merge-base HEAD origin/main)"
for root in "$PLAINSONG_BASELINE_ROOT" "$PLAINSONG_FIX_ROOT" "$PLAINSONG_STACK_ROOT"; do
  make -C "$root" generate
done
/usr/bin/python3 "$PLAINSONG_FIX_ROOT/docs/evidence/editor-highlight-schedule-20261002-idle.py"
```


## Handoff 22 retry after handoff 23 — 2026-10-04 (PR #136)

**Idle measurement still pending.** After PR #141 normal CI run 37178629394
passed at `323f672`, the five-minute typing admission was retried at candidate
`54ca2161d890ec7ae267bef90c333100f528a17e` against clean baseline `4cef0ccf44e422ad22ab34c4319a46c42e69b009`.
No other xcodebuild was present before admission. All eleven inside-lock checks
refused loads 3.24–4.74 (require <3); exit 75. No build or typing
probe ran and no performance samples exist for this retry. Maxima, medians and
pass/fail against 16 ms remain unmeasured; there is no regression conclusion.
The prior loaded runs remain diagnostics. Heavy-app/other-agent shutdown was
requested again before this retry.

Raw log: `docs/evidence/h22-post23-idle-admission.log`; JSON:
`docs/evidence/handoff22-pr136-20261004-post23-admission.json`. The exact idle rerun
commands are in the preceding Handoff 22 admission section. Fetch/merge main,
regenerate the three projects and remeasure before treating a future head as proven.
No budgets or owner-only gates changed.


## Handoff 22 retry after handoff 23 — 2026-10-04 (PR #137)

**Idle measurement still pending.** The sequential A/B retry after PR #141 CI
passed was prepared at stacked candidate `7a164fbbdf57333a483577c3467510709d4faf2b`,
with baseline `4cef0ccf44e422ad22ab34c4319a46c42e69b009`. Baseline admission
refused all eleven checks over five minutes (1-minute load 3.24–4.74, require <3),
so no product build, baseline/fix comparison or baseline/stack comparison ran.
The helper exited 75; no maxima, medians, 16 ms pass/fail or regression conclusion
exists for this retry. Latest #136 pending evidence is merged into this stack;
only evidence documents changed after the candidate was prepared.

Raw log: `docs/evidence/h22-post23-idle-admission.log`; JSON:
`docs/evidence/handoff22-pr137-20261004-post23-admission.json`. The exact rerun
commands remain in the preceding Handoff 22 admission section. Historical loaded
numbers remain diagnostics; R9, real IME and owner-only gates remain open.


## Handoff 22 third idle admission attempt - 2026-10-04 (PR #136)

**Idle measurement still pending.** Candidate `64b6476a5d589355fad179de55daf2f13442476f`,
baseline `4cef0ccf44e422ad22ab34c4319a46c42e69b009`. Missing temporary stack/baseline
checkouts were recreated from the retained branch and current main; all candidate
worktrees were clean and projects regenerated. Owner confirmed heavy-app/agent
shutdown readiness. No other xcodebuild was present before admission, but all
eleven inside-lock checks over five minutes refused loads 18.10-86.29 (require <3).
Exit 75; no build, typing probe or performance sample. Maxima/medians and 16 ms
pass/fail remain unmeasured; no regression conclusion or gate closure.

Raw log `docs/evidence/h22-retry3-idle-admission.log`; JSON
`docs/evidence/handoff22-pr136-20261004-retry3.json`. Exact rerun commands remain
in the first Handoff 22 admission section above; fetch/merge main, regenerate
projects and remeasure before claiming a later head. Budgets remain unchanged.


## Handoff 22 third idle admission attempt - 2026-10-04 (PR #137)

**Idle measurement still pending.** Prepared stacked candidate
`284a61f1e40a57e10f4d734155dd8f7996419850`, clean baseline
`4cef0ccf44e422ad22ab34c4319a46c42e69b009`. Owner confirmed readiness, but
baseline admission refused all eleven checks over five minutes at loads
18.10-86.29 (require <3); exit 75. No product build or A/B comparison was reached.
Zero samples, no maxima/medians, 16 ms pass/fail or regression conclusion.
Latest #136 docs-only evidence is merged; historical loaded runs remain diagnostics.

Raw log `docs/evidence/h22-retry3-idle-admission.log`; JSON
`docs/evidence/handoff22-pr137-20261004-retry3.json`. Exact shared-lock/environment
rerun commands remain above. R9, real IME and owner-only gates remain open.


## Handoff 22 fourth idle admission attempt - 2026-10-04 (PR #136)

**Idle measurement still pending.** Candidate `a7709ff499cf5a7632799e07d6999c93af2c0b65`, baseline/main
`4cef0ccf44e422ad22ab34c4319a46c42e69b009`. Owner confirmed idle readiness during admission;
no competing xcodebuild was present. All 11 inside-lock checks over five minutes refused 1-minute loads 4.08-5.66 (require <3), exit 75. No build or typing probe ran. The common helper stopped during baseline admission, so neither fix nor stack was measured. Maxima, medians, 16 ms pass/fail and any regression conclusion remain unmeasured.
No performance samples, budget changes or owner-only gate closures.

Raw logs: `docs/evidence/h22-retry4-idle-admission.log`.
Structured status: `docs/evidence/handoff22-pr136-20261004-retry4.json`.
Fetch and merge main if it advances, refresh the clean baseline to the fix/main
merge base, regenerate each project, then remeasure before claiming a later head.

```sh
export PLAINSONG_XCODEBUILD_LOCK=/private/tmp/plainsong-xcodebuild-test.lock
sysctl -n vm.loadavg
pgrep -fl xcodebuild # no matches required before each batch
export PLAINSONG_BASELINE_ROOT=/private/tmp/plainsong-h22-baseline
export PLAINSONG_FIX_ROOT=/Users/davis._.su/Documents/plainsong-highlight-schedule-fix
export PLAINSONG_STACK_ROOT=/private/tmp/plainsong-replace-wysiwyg
/usr/bin/python3 "$PLAINSONG_FIX_ROOT/docs/evidence/editor-highlight-schedule-20261002-idle.py"
```


## Handoff 22 fourth idle admission attempt - 2026-10-04 (PR #137)

**Idle measurement still pending.** Candidate `a6d2d436c9a1c091a6621b2df7ccff457ae0bb21`, baseline/main
`4cef0ccf44e422ad22ab34c4319a46c42e69b009`. Owner confirmed idle readiness during admission;
no competing xcodebuild was present. All 11 inside-lock checks over five minutes refused 1-minute loads 4.08-5.66 (require <3), exit 75. No build or typing probe ran. The common helper stopped during baseline admission, so neither fix nor stack was measured. Maxima, medians, 16 ms pass/fail and any regression conclusion remain unmeasured.
No performance samples, budget changes or owner-only gate closures.

Raw logs: `docs/evidence/h22-retry4-idle-admission.log`.
Structured status: `docs/evidence/handoff22-pr137-20261004-retry4.json`.
Fetch and merge main if it advances, refresh the clean baseline to the fix/main
merge base, regenerate each project, then remeasure before claiming a later head.

```sh
export PLAINSONG_XCODEBUILD_LOCK=/private/tmp/plainsong-xcodebuild-test.lock
sysctl -n vm.loadavg
pgrep -fl xcodebuild # no matches required before each batch
export PLAINSONG_BASELINE_ROOT=/private/tmp/plainsong-h22-baseline
export PLAINSONG_FIX_ROOT=/Users/davis._.su/Documents/plainsong-highlight-schedule-fix
export PLAINSONG_STACK_ROOT=/private/tmp/plainsong-replace-wysiwyg
/usr/bin/python3 "$PLAINSONG_FIX_ROOT/docs/evidence/editor-highlight-schedule-20261002-idle.py"
```


## Paired typing comparison under recorded load - 2026-10-04 (PR #137)

**Still pending: two complete pairs out of the required ten per mode.** This
supersedes the earlier idle-admission status as the current measurement plan.
True idle / absolute 16 ms acceptance remains with R9, PR I or an owner run;
the historical idle attempts above remain historical admission records.

Candidate `142efcf7daad63bd41c9485a90cbe011bbc85de3`; baseline
`4cef0ccf44e422ad22ab34c4319a46c42e69b009`. Owner confirmed other builds/tests were paused,
heavy-app shutdown, power and non-use readiness. The ceiling is 6, checked inside
the shared non-blocking lock together with exact-name compiler-process exclusion.
Every attempt records load and top five CPU processes; each batch records SHA.
The helper now generates projects after installing the isolated baseline test
probe. Its timed function and fixture hashes match all three products.

The first attempt ran zero baseline tests and was rejected. The second produced
one baseline batch (30 source-only and 30 WYSIWYG samples) but no candidate
samples: the candidate main thread blocked in `open` while reading its Documents
fixture, captured in the committed process sample. The owned runner and host were
terminated. Test-only fixture loading now uses the test bundle, including an
isolated resource-manifest overlay on baseline. Run3 built all three bundled-probe
products and completed two baseline/fix pairs per mode before waiting five minutes
for candidate pair 3; the third baseline batch is unpaired and excluded. Run4
rebuilt baseline and timed out before candidate build, adding no typing samples.
No stack typing batch ran. No product code changed. The original zero-pair summary
missed the completed run3 pairs; this entry and the structured evidence correct it.
The two complete pairs share the candidate SHAs and bundled probe used by run4.


The requested analysis is median/p95/max per batch, B-minus-A pair differences,
10,000 fixed-seed bootstrap resamples and a 95% CI of each median pair difference.
A regression signal needs CI wholly above +0.5 ms and candidate worse in at least
80% of pairs; otherwise the completed comparison reports no detected signal under
recorded load, with CI-width sensitivity. No documented warm-up is discarded.
Fractions over 16 ms for both products are observations, never absolute acceptance.
There are zero complete stack pairs, so no stack differences, CI or verdict.
The inherited #136 observations comprise two pairs per mode and show roughly
+6.7 ms WYSIWYG median differences, but remain below the ten-pair requirement.
They are not substituted for stack evidence. No absolute-budget conclusion or
gate closure is possible; R9, real IME and owner-only acceptance remain open.


Evidence: `docs/evidence/handoff22-pr137-20261004-paired.json`. Committed raw logs and rejected-attempt
metadata: `docs/evidence/h22-paired-20261004/`; xcresult paths remain in each JSON.
Pinned `make lint` passed (existing warnings, zero serious), statistical boundary
checks passed, and `git diff --check` is clean. A full correctness suite was not run.

Before retrying, fetch/merge main if it advances, prepare a clean detached baseline
at the fix/main merge base, pause other builds/tests and leave the Mac on power.
The helper installs its test-only baseline overlay before generating/building.
Use a new evidence directory for each run (the default is timestamped):

```sh
export PLAINSONG_XCODEBUILD_LOCK=/private/tmp/plainsong-xcodebuild-test.lock
export PLAINSONG_MAX_LOAD=6
export PLAINSONG_PAIRS=10
export PLAINSONG_BASELINE_ROOT=/private/tmp/plainsong-h22-baseline
export PLAINSONG_FIX_ROOT=/Users/davis._.su/Documents/plainsong-highlight-schedule-fix
export PLAINSONG_STACK_ROOT=/private/tmp/plainsong-replace-wysiwyg
/usr/bin/python3 "$PLAINSONG_FIX_ROOT/docs/evidence/editor-highlight-schedule-paired.py"
```


## Paired typing comparison under recorded load - 2026-10-04 (PR #136)

**Still pending: two complete pairs out of the required ten per mode.** This
supersedes the earlier idle-admission status as the current measurement plan.
True idle / absolute 16 ms acceptance remains with R9, PR I or an owner run;
the historical idle attempts above remain historical admission records.

Candidate `8360954ab845db9f233697f246fcf41c36588965`; baseline
`4cef0ccf44e422ad22ab34c4319a46c42e69b009`. Owner confirmed other builds/tests were paused,
heavy-app shutdown, power and non-use readiness. The ceiling is 6, checked inside
the shared non-blocking lock together with exact-name compiler-process exclusion.
Every attempt records load and top five CPU processes; each batch records SHA.
The helper now generates projects after installing the isolated baseline test
probe. Its timed function and fixture hashes match all three products.

The first attempt ran zero baseline tests and was rejected. The second produced
one baseline batch (30 source-only and 30 WYSIWYG samples) but no candidate
samples: the candidate main thread blocked in `open` while reading its Documents
fixture, captured in the committed process sample. The owned runner and host were
terminated. Test-only fixture loading now uses the test bundle, including an
isolated resource-manifest overlay on baseline. Run3 built all three bundled-probe
products and completed two baseline/fix pairs per mode before waiting five minutes
for candidate pair 3; the third baseline batch is unpaired and excluded. Run4
rebuilt baseline and timed out before candidate build, adding no typing samples.
No stack typing batch ran. No product code changed. The original zero-pair summary
missed the completed run3 pairs; this entry and the structured evidence correct it.
The two complete pairs share the candidate SHAs and bundled probe used by run4.


The requested analysis is median/p95/max per batch, B-minus-A pair differences,
10,000 fixed-seed bootstrap resamples and a 95% CI of each median pair difference.
A regression signal needs CI wholly above +0.5 ms and candidate worse in at least
80% of pairs; otherwise the completed comparison reports no detected signal under
recorded load, with CI-width sensitivity. No documented warm-up is discarded.
Fractions over 16 ms for both products are observations, never absolute acceptance.
For #136, two-pair observations (60 samples per product per mode), in milliseconds:

| Mode | Baseline median / p95 / max | Candidate median / p95 / max | Fraction >16 ms A / B |
|---|---|---|---|
| source-only | 14.150 / 14.856 / 14.924 | 14.234 / 14.927 / 15.414 | 0 / 0 |
| WYSIWYG | 7.513 / 15.007 / 15.086 | 14.219 / 15.078 / 17.418 | 0 / 1/60 |

Per-pair median differences: source-only `[6.6984, 0.0507]`, WYSIWYG
`[6.7456, 6.6946]`; p95 differences: source-only `[0.6327, 0.0451]`, WYSIWYG
`[0.4957, 0.2429]`. Candidate is worse in 2/2 pairs for both metrics/modes.
Exploratory median-difference bootstrap CIs are source-only `[0.0507, 6.6984]`
and WYSIWYG `[6.6946, 6.7456]`; p95-difference CIs are `[0.0451, 0.6327]`
and `[0.2429, 0.4957]`. With only two pairs these resamples do not establish
population precision or satisfy the >=10-pair rule: **no formal verdict**.
The WYSIWYG median increase needs the full paired run; it is not dismissed as
noise. The raw early metric flag is exploratory; the corrected derived analysis
requires ten pairs for any regression flag. Per-batch loads and all thirty
keystroke samples are in the run3 JSON. No absolute-budget conclusion or gate
closure is possible; R9, real IME and owner-only acceptance remain open.


Evidence: `docs/evidence/handoff22-pr136-20261004-paired.json`. Committed raw logs and rejected-attempt
metadata: `docs/evidence/h22-paired-20261004/`; xcresult paths remain in each JSON.
Pinned `make lint` passed (existing warnings, zero serious), statistical boundary
checks passed, and `git diff --check` is clean. A full correctness suite was not run.

Before retrying, fetch/merge main if it advances, prepare a clean detached baseline
at the fix/main merge base, pause other builds/tests and leave the Mac on power.
The helper installs its test-only baseline overlay before generating/building.
Use a new evidence directory for each run (the default is timestamped):

```sh
export PLAINSONG_XCODEBUILD_LOCK=/private/tmp/plainsong-xcodebuild-test.lock
export PLAINSONG_MAX_LOAD=6
export PLAINSONG_PAIRS=10
export PLAINSONG_BASELINE_ROOT=/private/tmp/plainsong-h22-baseline
export PLAINSONG_FIX_ROOT=/Users/davis._.su/Documents/plainsong-highlight-schedule-fix
export PLAINSONG_STACK_ROOT=/private/tmp/plainsong-replace-wysiwyg
/usr/bin/python3 "$PLAINSONG_FIX_ROOT/docs/evidence/editor-highlight-schedule-paired.py"
```


## Current recorded-load paired result - 2026-10-04 (PR #136)

**Complete: ten interleaved baseline/candidate pairs per mode. No regression signal
detected under recorded load by the handoff rule.** This supersedes the preceding
pending and exploratory two-pair entries; those remain historical diagnostics.
Candidate `e438ac19c91388326280e39bcfafc104fa8bc58c`; common baseline
`4cef0ccf44e422ad22ab34c4319a46c42e69b009`. #137 measures the full stacked head against this
same baseline; it does not isolate Replace from the inherited scheduler change.

Each batch has 30 native keystrokes in source-only and WYSIWYG with the production
Find debounce; 300 samples per product/mode. No documented warm-up iteration exists,
so none was removed from either product. Timed probe and fixture SHA-256 match all
three products. Baseline retains its product HEAD and uses the reproducible test-only
source/resource overlay installed by the helper. Only measurement plumbing, test
instrumentation and test resource/scheme membership changed; product code is unchanged.

Start load range `3.10-5.36`, end `3.10-12.59`.
Every batch passed load <=6 and exact-name compiler exclusion **inside** the shared
non-blocking lock. End loads can exceed the admission ceiling; all numbers are
observed under recorded load, with top five CPU processes captured per batch.
Owner confirmed other builds/tests paused, heavy-app shutdown, power and non-use.

Pooled native typing observations (milliseconds; maxima include all iterations):

| Mode | Baseline median / p95 / max | Candidate median / p95 / max | Fraction >16 ms A / B |
|---|---|---|---|
| source-only | 14.181 / 14.901 / 190.683 | 14.151 / 14.768 / 20.531 | 0.67% / 0.33% |
| wysiwyg | 14.216 / 14.813 / 19.808 | 14.202 / 14.708 / 14.978 | 0.33% / 0.00% |

Per-pair B-minus-A statistics; fixed seed 20261004, 10,000 bootstrap resamples of
the median pair difference. Each pair's medians/p95 and all samples are in JSON:

| Mode / pair statistic | Median difference ms | Bootstrap 95% CI ms | B worse |
|---|---|---|---|
| source-only median_ms | -0.059 | [-0.162, 3.298] | 4/10 |
| source-only p95_ms | -0.104 | [-0.414, 0.007] | 2/10 |
| wysiwyg median_ms | -0.023 | [-6.726, 6.733] | 4/10 |
| wysiwyg p95_ms | 0.007 | [-0.163, 0.034] | 6/10 |

A signal requires the CI entirely above +0.5 ms **and** B worse in >=8/10 pairs.
Neither metric/mode satisfies both. This is detection under recorded load, not a
claim of equivalence. CI widths bound sensitivity; the #136 WYSIWYG median CI is
particularly wide (about 13.46 ms). The earlier two-pair +6.7 ms trend was not
consistently reproduced across the complete run. Narrower p95 CIs mean not every
comparison was inconclusive, so the optional CPU-time instrumentation was not added.
The pooled #137 tails exceed 16 ms more often than baseline despite no median-pair
signal; these observations remain visible and are not dismissed or called idle proof.
No absolute 16 ms pass/fail is claimed. R9 / PR I, real IME, physical input and
owner-only acceptance remain open. No performance budget changed or gate closed.

Evidence: `docs/evidence/handoff22-pr136-20261004-paired-final.json`; complete batch metadata, raw logs,
and admission checks: `docs/evidence/h22-paired-20261004/run5/`. xcresult bundles
are retained at the printed paths in those JSONs. Named tests:
`EditorFindHostedGateTests.testHostedLargeFixtureSourceOnlyTypingStaysUnderBudget`
and `testHostedLargeFixtureWYSIWYGTypingStaysUnderBudget`. Both executed in every
accepted batch. Only the existing 16 ms assertion failed in 3
batches for this comparison; there were no functional failures or missing samples.
Pinned lint, statistical boundary checks and `git diff --check` passed. This is not
a full correctness-suite or current-head CI claim.

Reproduce after fetching/merging main if needed and refreshing a clean baseline to
the fix/main merge base; pause other builds/tests and leave the Mac on power:

```sh
export PLAINSONG_XCODEBUILD_LOCK=/private/tmp/plainsong-xcodebuild-test.lock
export PLAINSONG_MAX_LOAD=6
export PLAINSONG_PAIRS=10
export PLAINSONG_BASELINE_ROOT=/private/tmp/plainsong-h22-baseline
export PLAINSONG_FIX_ROOT=/Users/davis._.su/Documents/plainsong-highlight-schedule-fix
export PLAINSONG_STACK_ROOT=/private/tmp/plainsong-replace-wysiwyg
/usr/bin/python3 "$PLAINSONG_FIX_ROOT/docs/evidence/editor-highlight-schedule-paired.py"
```

## Export PR F Phase B — 2026-10-01: pending idle-machine run

Correctness, package/hosted regressions, pinned lint and the native build finished before
E9 was attempted. Under the shared Xcode lock, the final idle checks reported 1-minute
load 35.84 for Debug and 35.21 for Release (the conservative idle threshold is <= 1.0).
Both scripts exited 75: **pending idle-machine run; no performance samples recorded**.
These load readings are an environment check, not export performance evidence.

Run from `/Users/davis._.su/Documents/plainsong-export-html-command` after the machine is idle:

```sh
Scripts/run-export-html-e9.sh Debug
Scripts/run-export-html-e9.sh Release
```

The scripts retain `Results.xcresult` and `run.log` under their printed evidence directory.
The final hosted compilation probe executed three tests with three deliberate opt-in
skips and zero failures; it verifies the entry points compile, not that a budget passes.

Pending measurements:
- `ExportHTMLPerformanceTests.testProductionOffscreenExportTimeAndHostMemory`: three
  full-command samples each for `large-1mb.md` and `export-f-heavy.md`, with 24 distinct
  valid bounded PNG assets; elapsed time and peak host RSS sampled every 5 ms. WebKit
  helper-process memory and an exact OS high-water mark are not claimed.
- `AppBackedEditorPerformanceTests.testTypingDuringActiveHTMLExportStaysWithinTheExistingFrameBudget`:
  native input plus public-view update while export is active, using the existing 16 ms
  typing budget. This remains synthetic AppKit evidence.
- `ExportHTMLPerformanceTests.testSixtyFourMiBWriterMainActorTime`: three synchronous
  `writeExportArtifact` calls at the 64 MiB cap; byte allocation is outside the timer.
- Real iCloud evicted-leaf materialization and coordination wait, responsiveness and
  physical-input/compositor evidence remain owner-only, using the real save panel.

No export-specific time or memory budget is frozen. If the writer noticeably stalls
input, stop for an E2-contract review before moving any writer work off-main. See
`docs/export-html-phase-b-checklist.md` for the owner entry points and unchecked smoke cases.


## Export F E9 idle admission — 2026-10-04

**Pending idle-machine run.** Candidate product SHA `ea2e723fdd3388981b75e467751bf4f57ab2bb6b` includes main
`4cef0ccf44e422ad22ab34c4319a46c42e69b009`. Debug and Release admission both exited 75 at 1-minute load 8.15
(require ≤1.0); neither built nor recorded any performance samples. The required
three runs per configuration, fixture wall times/peak memory, typing during export,
and 64 MiB writer main-thread time remain pending. Budgets are unchanged and no
E9, keyboard or VoiceOver acceptance checkbox is closed. No writer decision can
be made from these admission-only runs.

Raw logs: `docs/evidence/h22-e9-debug-admission.log` and
`docs/evidence/h22-e9-release-admission.log`. Structured status:
`docs/evidence/handoff22-pr138-20261004-admission.json`.

```sh
export PLAINSONG_XCODEBUILD_LOCK=/private/tmp/plainsong-xcodebuild-test.lock
sysctl -n vm.loadavg
pgrep -fl xcodebuild # no matches required before each batch
Scripts/run-export-html-e9.sh Debug
Scripts/run-export-html-e9.sh Release
# Obtain at least three qualified runs per configuration, checking admission each time.
```


## Export F E9 retry after handoff 23 — 2026-10-04

**Pending idle-machine run.** After PR #141 normal CI run 37178629394 passed,
E9 was retried at candidate `f472bd56434b31a4eca43e747b7f0a113e48fb6d`, which
includes main `4cef0ccf44e422ad22ab34c4319a46c42e69b009`. No other xcodebuild
was present before either batch. Debug refused 1-minute load 4.67 and Release
refused 5.34 (require ≤1.0); both exited 75 before building or measuring.
There are zero qualified runs; the required ≥3 per configuration, fixture wall
time/peak memory, typing during export and 64 MiB writer time remain pending.
No performance or writer-off-main conclusion is possible, no budget changed
and no E9 or owner-only keyboard/VoiceOver box was checked.

Raw logs: `docs/evidence/h22-post23-e9-debug-admission.log` and
`docs/evidence/h22-post23-e9-release-admission.log`; JSON:
`docs/evidence/handoff22-pr138-20261004-post23-admission.json`. Use the exact
shared-lock/load/process-check commands in the preceding E9 admission section
and repeat each configuration until three qualified runs exist.


## Export F E9 third idle admission attempt - 2026-10-04

**Pending idle-machine run.** Candidate `72a5a6974a61e7742edda13f9f377ef22f4eedce`,
including main `4cef0ccf44e422ad22ab34c4319a46c42e69b009`. Owner confirmed
readiness; no other xcodebuild was present before either batch. Debug refused
load 15.23 and Release refused 14.00 (require <=1.0), both exit 75 before build
or measurement. Zero qualified runs; at least three per configuration, fixture
wall time/peak memory, typing during export and 64 MiB writer time remain pending.
No writer decision, budget change, E9 box or owner acceptance closure.

Raw logs `docs/evidence/h22-retry3-e9-debug-admission.log` and
`docs/evidence/h22-retry3-e9-release-admission.log`; JSON
`docs/evidence/handoff22-pr138-20261004-retry3.json`. Exact shared-lock/load/process
check and Debug/Release commands remain in the first E9 admission section above.


## Export F E9 fourth idle admission attempt - 2026-10-04

**Pending idle-machine run.** Candidate `b64fc771f2b6b88dfadcb639da2866444551ac7f`, baseline/main
`4cef0ccf44e422ad22ab34c4319a46c42e69b009`. Owner confirmed idle readiness during admission;
no competing xcodebuild was present. Debug and Release each refused 1-minute load 4.10 (require <=1.0), exit 75. Zero qualified runs; at least three runs per configuration, fixture wall time/peak memory, typing during export and 64 MiB writer main-thread time remain pending. No writer-off-main conclusion is possible.
No performance samples, budget changes or owner-only gate closures.

Raw logs: `docs/evidence/h22-retry4-e9-debug-admission.log`, `docs/evidence/h22-retry4-e9-release-admission.log`.
Structured status: `docs/evidence/handoff22-pr138-20261004-retry4.json`.
Fetch and merge main if it advances, refresh the clean baseline to the fix/main
merge base, regenerate each project, then remeasure before claiming a later head.

```sh
export PLAINSONG_XCODEBUILD_LOCK=/private/tmp/plainsong-xcodebuild-test.lock
sysctl -n vm.loadavg
pgrep -fl xcodebuild # no matches required before each batch
Scripts/run-export-html-e9.sh Debug
Scripts/run-export-html-e9.sh Release
# Obtain at least three qualified runs per configuration.
```


## Current Export F E9 recorded-load results - 2026-10-04

**Complete: ten Debug and ten testable-Release export runs, each paired with a
same-session/configuration no-export typing batch.** Debug/Release were interleaved;
build-for-testing occurred once per scheme/configuration, then all measurement
batches used test-without-building. Candidate `9c4fab94745843495142609e3392b306b9250da1` includes main
`4cef0ccf44e422ad22ab34c4319a46c42e69b009`. This supersedes earlier idle-pending
measurement entries. It is **observed under recorded load**, not idle acceptance.

Every batch passed inside-lock load <=6 and no other named compiler processes;
start load `1.58-5.55`, end `1.69-5.55`.
Top five CPU processes and product SHA are retained for each batch. Owner confirmed
quiet readiness. Release retains -O but enables existing @testable seams, which can
affect timing/optimization; these are testable-Release, not retail-binary numbers.
The dedicated PerformanceTests scheme avoids unrelated Debug-only AppTests. Earlier
build/array/signature failures and their fixes are preserved as historical logs.

Production offscreen export: 30 wall-time samples per fixture/configuration and ten
peak sampled host RSS values, with 24 distinct bounded PNG paths. Values are median
(range); wall time includes the full production command path:

| Configuration / fixture | Wall ms median (range) | Peak sampled host RSS MiB median (range) |
|---|---|---|
| Debug large-1mb.md | 2186.268 (2127.153-2311.474) | 183.711 (181.703-193.188) |
| Debug export-f-heavy.md | 1086.125 (1049.820-1141.593) | 184.297 (182.328-193.906) |
| Release large-1mb.md | 2196.496 (2132.693-2389.395) | 177.016 (173.094-181.797) |
| Release export-f-heavy.md | 1081.214 (1039.884-1131.938) | 177.148 (171.844-180.703) |

RSS is sampled every 5 ms for the host, not an exact OS high-water mark or WebKit
helper-process memory. Real iCloud materialization/coordination remains owner work.

Typing (native input plus scheduled public-view update; one keystroke per batch):

| Config | No-export median / p95 / max ms | Active-export median / p95 / max ms | Median B-A; bootstrap 95% CI ms | B worse | >16 ms A / B |
|---|---|---|---|---|---|
| Debug | 13.917 / 15.524 / 15.571 | 6.085 / 31.922 / 36.191 | -5.759; [-9.641, 10.212] | 3/10 | 0% / 30% |
| Release | 13.738 / 15.057 / 15.142 | 5.769 / 11.123 / 11.340 | -6.063; [-8.583, -3.949] | 1/10 | 0% / 0% |

One sample means each batch's median/p95/max coincide; all ten pair differences
are in JSON. Bootstrap uses 10,000 resamples, seed 20261004. Neither configuration
meets CI entirely above +0.5 ms and B worse in >=8/10 pairs: **no regression signal
detected under recorded load**. Debug has a wide CI (~19.85 ms), so meaningful
median penalties cannot be excluded; 3/10 active-export samples exceeded 16 ms,
maximum ~36.19 ms. These are reported, not declared harmless or a green absolute
budget. Release has no >16 ms sample but does not establish idle/physical acceptance.

Synchronous main-actor writeExportArtifact at 64 MiB (30 samples/configuration;
allocation outside timer), milliseconds:

| Config | Median ms | Range ms |
|---|---|---|
| Debug | 17.869 | 14.925-49.577 |
| Release | 15.097 | 14.013-24.767 |

No relative-regression trigger or hundreds-of-ms writer sample occurred, so the
specified writer-off-main owner decision trigger is not met. This does not prove
absence of all UI stalls. No writer changes or export-specific budget was frozen.

Named tests: `ExportHTMLPerformanceTests.testProductionOffscreenExportTimeAndHostMemory`,
`testSixtyFourMiBWriterMainActorTime`,
`AppBackedEditorPerformanceTests.testTypingDuringActiveHTMLExportStaysWithinTheExistingFrameBudget`,
and `testTypingWithoutHTMLExportForRecordedLoadComparison`. All 40 batches produced
complete named samples and valid functional checks; three Debug export batches
exited 65 solely for the existing 16 ms assertion. Other 37 batches exited 0.

Evidence: `docs/evidence/handoff22-pr138-20261004-paired-final.json`; raw logs and start/end snapshots under
`docs/evidence/h22-e9-paired-20261004/`. xcresults are retained at paths in JSON.
Only E9's measuring-and-recording checkbox is closed. Absolute 16 ms, keyboard,
VoiceOver, Powerbox/iCloud and broad regression-suite acceptance remain open.
Pinned lint, Bash syntax, bootstrap boundary and diff checks passed; no full-suite
or current-head CI green claim is made.

Exact full-run command (after fetch/merge main if necessary; pause other builds/tests):

```sh
export PLAINSONG_XCODEBUILD_LOCK=/private/tmp/plainsong-xcodebuild-test.lock
export PLAINSONG_MAX_LOAD=6
export PLAINSONG_PAIRS=10
/usr/bin/python3 Scripts/run-export-html-e9-paired.py
```

## Current recorded-load paired result - 2026-10-04 (PR #137)

**Complete: ten interleaved baseline/candidate pairs per mode. No regression signal
detected under recorded load by the handoff rule.** This supersedes the preceding
pending and exploratory two-pair entries; those remain historical diagnostics.
Candidate `2306bdb86eae40517dc9806edb4bf2664280cc22`; common baseline
`4cef0ccf44e422ad22ab34c4319a46c42e69b009`. #137 measures the full stacked head against this
same baseline; it does not isolate Replace from the inherited scheduler change.

Each batch has 30 native keystrokes in source-only and WYSIWYG with the production
Find debounce; 300 samples per product/mode. No documented warm-up iteration exists,
so none was removed from either product. Timed probe and fixture SHA-256 match all
three products. Baseline retains its product HEAD and uses the reproducible test-only
source/resource overlay installed by the helper. Only measurement plumbing, test
instrumentation and test resource/scheme membership changed; product code is unchanged.

Start load range `4.60-5.98`, end `4.60-9.16`.
Every batch passed load <=6 and exact-name compiler exclusion **inside** the shared
non-blocking lock. End loads can exceed the admission ceiling; all numbers are
observed under recorded load, with top five CPU processes captured per batch.
Owner confirmed other builds/tests paused, heavy-app shutdown, power and non-use.

Pooled native typing observations (milliseconds; maxima include all iterations):

| Mode | Baseline median / p95 / max | Candidate median / p95 / max | Fraction >16 ms A / B |
|---|---|---|---|
| source-only | 14.189 / 14.722 / 15.066 | 14.190 / 16.857 / 17.856 | 0.00% / 5.67% |
| wysiwyg | 14.245 / 14.926 / 15.407 | 14.256 / 16.919 / 17.121 | 0.00% / 5.33% |

Per-pair B-minus-A statistics; fixed seed 20261004, 10,000 bootstrap resamples of
the median pair difference. Each pair's medians/p95 and all samples are in JSON:

| Mode / pair statistic | Median difference ms | Bootstrap 95% CI ms | B worse |
|---|---|---|---|
| source-only median_ms | -0.015 | [-0.127, 1.370] | 4/10 |
| source-only p95_ms | 0.038 | [-0.034, 0.277] | 8/10 |
| wysiwyg median_ms | 0.008 | [-3.488, 0.033] | 6/10 |
| wysiwyg p95_ms | -0.020 | [-0.173, 0.317] | 4/10 |

A signal requires the CI entirely above +0.5 ms **and** B worse in >=8/10 pairs.
Neither metric/mode satisfies both. This is detection under recorded load, not a
claim of equivalence. CI widths bound sensitivity; the #136 WYSIWYG median CI is
particularly wide (about 13.46 ms). The earlier two-pair +6.7 ms trend was not
consistently reproduced across the complete run. Narrower p95 CIs mean not every
comparison was inconclusive, so the optional CPU-time instrumentation was not added.
The pooled #137 tails exceed 16 ms more often than baseline despite no median-pair
signal; these observations remain visible and are not dismissed or called idle proof.
No absolute 16 ms pass/fail is claimed. R9 / PR I, real IME, physical input and
owner-only acceptance remain open. No performance budget changed or gate closed.

Evidence: `docs/evidence/handoff22-pr137-20261004-paired-final.json`; complete batch metadata, raw logs,
and admission checks: `docs/evidence/h22-paired-20261004/run5/`. xcresult bundles
are retained at the printed paths in those JSONs. Named tests:
`EditorFindHostedGateTests.testHostedLargeFixtureSourceOnlyTypingStaysUnderBudget`
and `testHostedLargeFixtureWYSIWYGTypingStaysUnderBudget`. Both executed in every
accepted batch. Only the existing 16 ms assertion failed in 2
batches for this comparison; there were no functional failures or missing samples.
Pinned lint, statistical boundary checks and `git diff --check` passed. This is not
a full correctness-suite or current-head CI claim.

Reproduce after fetching/merging main if needed and refreshing a clean baseline to
the fix/main merge base; pause other builds/tests and leave the Mac on power:

```sh
export PLAINSONG_XCODEBUILD_LOCK=/private/tmp/plainsong-xcodebuild-test.lock
export PLAINSONG_MAX_LOAD=6
export PLAINSONG_PAIRS=10
export PLAINSONG_BASELINE_ROOT=/private/tmp/plainsong-h22-baseline
export PLAINSONG_FIX_ROOT=/Users/davis._.su/Documents/plainsong-highlight-schedule-fix
export PLAINSONG_STACK_ROOT=/private/tmp/plainsong-replace-wysiwyg
/usr/bin/python3 "$PLAINSONG_FIX_ROOT/docs/evidence/editor-highlight-schedule-paired.py"
```

## Reconciled-source presentation — 2026-10-05

Handoff 21 starts from `91f0ebac` after #136/#137 merged. All four
`applyReconciledSource` callers retain the whole-source assignment, selection clamp,
writer/source reconciliation and undo semantics. Only that restore requests the
normal `EditorHighlightScheduler` restart, including when App text is unchanged.
The 20 ms debounce and off-main parse are unchanged; marked-text and native-editing
apply guards remain intact. Ordinary accepted input does not invoke the new hook.
The hook is installed only after the exact document transition succeeds and removed
on dismantle, so a deferred destination cannot replace the old source's callback.

While the new parse is pending, backing text is raw. A persistent revision floor
blocks already-produced pre-restore highlights; cancelled scheduler work cannot
apply later. Resetting image presentation advances its generation, cancels returning
loads and clears cached plans even when source samples are identical. Replace's
presentation snapshot and Find decoration materialisation are invalidated as well.

Verification: full EditorKit **426 tests, seven real-IME opt-in skips, zero
failures**; full MarkdownCore **303 tests, zero failures**. The nine named
`EditorReconciledSourcePresentationTests` cover all four callers, clamped selection,
raw pending projection, syntax/link/fold/image equivalence to an independent parse,
marked-text deferral, an already-produced but unapplied stale revision, and no new
reconciliation request on an ordinary native edit. The existing PR F rejection test
now waits for the automatic scheduler pass without intervening input.

Hosted Find/Replace and all nine WYSIWYG policy tests: **119 tests, two typing
opt-in skips, zero failures**. Both new rejected-publication tests ran, checking
unchanged App source/revision/binding, no undo/redo, restored syntax/folds and a ready
image thumbnail. The opt-in highlight stress completed **0 drops in 60 operations**.
Temporarily disabling only the restart hook reproduced the source-mode recovery
timeout; restoring it passed. This is a source-mode negative control: WYSIWYG's
internal selection-driven scheduler can also request a reparse. The independent
oracle restores custom fold attributes from its own fresh plan after Foundation's
AttributedString bridge, without applying anything to the live editor.

`make build`, pinned SwiftFormat **0.62.1** `make lint` and `git diff --check` passed.
Hosted xcresult reports six runtime warnings (Environment reads in existing test
support and a QoS wait); this does not attribute their cause. These are the two full
package suites and required hosted slices, not a claim that all `make test` targets
ran. Real keyboard/IME acceptance and absolute R9/§12 typing acceptance remain owner
gates.

### Handoff 21a review fixes

The publication tests now wait for the initial failed thumbnail marker to settle
before reconciliation. Omitting only `presentationWasReset` makes both accepted
and rejected publication cases time out on the restored marker. Both hosted
refusal tests assert Find markers across the current match before and after the
restore; omitting all three Find-cache resets fails both tests at that assertion.
These mutations were temporary and restored before the final positive runs.

Writer-activation synchronization and rejection now publish a changed clamped
selection before requesting presentation. The new heading-boundary test supplies
the selection binding used by parsing and proves the callback sees that clamp;
omitting publication fails both writer paths. Six lifecycle tests prove dismantle
clears the handler, marked-text transitions retain the installed document's
handler until completion, a superseded destination never installs its handler,
and a callback inside a representable update runs after selection publication.
Deferred requests coalesce and are cancelled by dismantle or a completed document
transition; every highlight result stays blocked until the deferred request runs.

Final review-fix verification: full EditorKit **433 tests, seven real-IME opt-in
skips, zero failures**; full MarkdownCore **303 tests, zero failures**; all hosted
`EditorFind*`/`EditorReplace*` classes and nine WYSIWYG policy tests **127 tests,
two typing opt-in skips, zero failures**. Highlight-scheduler stress applied all
**60 edits, zero drops**. `make build`, pinned SwiftFormat **0.62.1** `make lint`
(zero serious violations), and `git diff --check` passed. Hosted/build validation
held the shared xcodebuild lock. This is the required suite scope, not a full
`make test` claim. No new typing measurement or additional gate closure is claimed;
Keep Mine and the second-merge rejected Replace All hosted test remain follow-ups.

### Paired typing comparison under recorded load

Compared clean merge-base `91f0ebaca7b15d8b0994ba9ac6cf0f89016f3a75` with the
fixed implementation commit `e0f26ceb2f104106eb7e1ed34de7ead9ba16af70`. The evidence
commit changes only documentation and measurement artifacts. Each Debug product was
built once, then measured with `test-without-building`: AB interleaved, ten pairs
per mode, 30 keystrokes per mode per batch, no documented warm-up discarded.
Fixture, project manifest and typing-probe hashes matched. Source fingerprints and
prebuilt executable hashes are recorded in the evidence.

Every admitted batch held `/private/tmp/plainsong-xcodebuild-test.lock`, had no other
build processes and began at one-minute load **4.963–5.989**, below the revised
Handoff 22 ceiling of 6. End loads were **4.993–9.783**. The Mac was on AC power;
27 rejected admission attempts were retained. This is recorded-load comparison,
not an idle-machine claim.

| Mode | Product | Samples | Median ms | p95 ms | Maximum ms | Over 16 ms |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Source-only | Baseline | 300 | 14.201 | 17.040 | 18.631 | 12.00% |
| Source-only | Candidate | 300 | 14.191 | 14.757 | 15.803 | 0.00% |
| WYSIWYG | Baseline | 300 | 14.259 | 17.169 | 20.461 | 11.67% |
| WYSIWYG | Candidate | 300 | 14.235 | 14.657 | 20.157 | 1.00% |

Per-pair `candidate − baseline` differences use the median of ten differences and a
95% bootstrap CI (10,000 resamples, seed 20261004):

| Mode / metric | Median difference ms | 95% CI ms | Candidate worse |
| --- | ---: | --- | ---: |
| Source-only median | -0.066 | [-1.380, -0.012] | 1/10 |
| Source-only p95 | -0.049 | [-1.383, +0.054] | 3/10 |
| WYSIWYG median | -2.803 | [-6.726, +0.008] | 3/10 |
| WYSIWYG p95 | -0.281 | [-1.647, -0.041] | 2/10 |

**No regression signal detected under recorded load** in either mode: neither
metric met the rule requiring the entire CI above +0.5 ms and candidate worse in
at least 8/10 pairs. CI widths are 1.368/1.437 ms for source-only median/p95 and
6.733/1.605 ms for WYSIWYG. The wide WYSIWYG median CI limits sensitivity; smaller
effects cannot be excluded, and these observations do not establish a speedup.

The AB order always ran baseline first. Baseline exceeds 16 ms in 12%/11.67%
of samples versus candidate 0%/1%; a hook that only adds work cannot explain that
apparent gain. A systematic order or environment effect of roughly 1–3 ms could
hide a regression of similar size. Samples are bimodal, clustering around 0.7 ms
and 14–17 ms; the roughly −6.7 ms WYSIWYG median differences reflect switches
between those modes, limiting interpretation of the median and its CI. Future
comparisons should use counterbalanced ABBA ordering. These historical samples
retain their original order.

The stronger typing-path evidence is static: ordinary accepted input cannot reach
the hook (`testOrdinaryNativeEditDoesNotRequestReconciliationPresentation`).
Per-update work remains one closure allocation and O(1) revision/installation
comparisons. Selection publication and deferred callback scheduling happen only
on reconciliation.

Five batches returned exit 65 solely for the probe's existing 16 ms assertion
(baseline 1/2/4/7, candidate 1); all 20 batches had both complete 30-sample series,
with no functional failures. The over-budget fractions remain observations under
load. Absolute §12/R9 typing acceptance and real keyboard/IME acceptance stay open.

Evidence: `docs/evidence/handoff21-reconciled-presentation-20261005-paired.json`
contains every raw sample, per-pair difference, admission snapshot and exact product
SHA. Raw logs, source manifests and xcresults remain at its printed paths under
`/private/tmp/plainsong-h21-typing-evidence/`. The runner used for these measurements
was saved at `31ff976` as
`docs/evidence/reconciled-source-presentation-paired.py` (historical SHA-256
`8c95985b66c2429212d127bf1a8ed48add8b1e417eab27e9efeff03a3ee9817e`). The current
runner requires explicit baseline/candidate roots; its measurement logic is
unchanged. Statistics were independently recomputed, and all 1,200 samples matched
their raw logs.

To reproduce, use clean isolated worktrees at the two exact implementation SHAs
above, generate their projects and prebuild each under the shared lock. Leave the
Mac on power and pause other builds/tests. Copy the runner outside those worktrees,
then run with fresh output paths:

```sh
export PLAINSONG_XCODEBUILD_LOCK=/private/tmp/plainsong-xcodebuild-test.lock
# Run once in each exact-SHA worktree, using its own derived-data directory:
lockf -k "$PLAINSONG_XCODEBUILD_LOCK" make generate
lockf -k "$PLAINSONG_XCODEBUILD_LOCK" xcodebuild -project Plainsong.xcodeproj \
  -scheme Plainsong -configuration Debug -destination platform=macOS \
  -derivedDataPath /private/tmp/h21-retry-PRODUCT-dd build-for-testing
# Supply those two worktrees and prebuilt product directories:
python3 /private/tmp/reconciled-source-presentation-paired.py \
  --baseline-root /private/tmp/h21-retry-baseline \
  --candidate-root /private/tmp/h21-retry-candidate \
  --baseline-derived-data /private/tmp/h21-retry-baseline-dd \
  --candidate-derived-data /private/tmp/h21-retry-candidate-dd \
  --candidate-sha e0f26ceb2f104106eb7e1ed34de7ead9ba16af70 \
  --evidence-dir /private/tmp/h21-retry-evidence
```
