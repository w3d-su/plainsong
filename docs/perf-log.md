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

The six-run proxy baseline is locally auditable again. Three Debug and three Release runs measure
the exact clean detached source commit `c871ddf5c66c17f03fd9456b53f79411f9b2e979`; the compact
records are committed under `docs/performance-evidence/editor-find-f2/2026-08-08-c871ddf5`, and
the omitted 1.2 GiB source/build/result artifacts are retained read-only at the owner-local root
shown below. The compact audit is deliberately `PARTIAL/OPEN`; only an audit that also receives
that full root prints proxy `PASS`.

This is not a portable or externally durable closure. The full root has not been replicated off
this Mac, and no authority to upload 1.2 GiB of artifacts was granted. Loss of that root invalidates
the full baseline and requires six fresh runs. Consequently the overall F2 retention item remains
open even though the currently present full root passes. The full `<16 ms` keystroke-to-screen,
F8 highlight apply/clear, F9, and combined-tip gates also remain open.

### Recovery finding and replacement policy

The July record claimed six `/private/tmp/plainsong-f2-c871ddf-{debug,release}-run{1,2,3}`
prefixes retained raw logs, digests, warning checks, manifests, xcresults, inspection copies, and
products. Those directories no longer contained the claimed files. An exhaustive local/session
search recovered exact copies of 18 of the 24 text-hash rows, but none of the six raw xcresult
bundles. Because warning/result and product provenance could not be fully audited, every July raw
number and hash is superseded and is not used below.

The replacement policy is fail-closed:

- `/private/tmp` is execution staging only and is never described as durable evidence.
- Every accepted run uses a fresh output prefix and is copied from execution staging to an
  owner-local, read-only Documents root before staging cleanup. Reused paths are rejected.
- The Git pack retains every raw text artifact, a strict inventory, summaries, and provenance. Its
  exact `SHA256SUMS` bytes are frozen by the checker.
- Full audit additionally rehashes private snapshots of the source archive/generated source,
  resolved package inputs, build manifests, host bundles, xctestrun files, raw logs, raw xcresults,
  and authoritative inspection xcresults. Source/build/product and per-run result identities are
  baseline-specific constants, not values trusted from the pack itself.
- Owner-local storage is not off-machine durability. Until the full root is published to an
  authorized durable store and re-audited there, F2 retention stays open.

### Exact environment and retained locations

| Field | Value |
|---|---|
| Measurement date | 2026-08-08 (Asia/Taipei) |
| Branch | `codex/editor-find-f2-performance-probe` |
| Measured source | clean detached `c871ddf5c66c17f03fd9456b53f79411f9b2e979`; `origin/main` at `250e91e16a1fd5339096ec96b84fcfe6e9790c4c` is an ancestor |
| macOS | 27.0 (26A5388g) |
| Xcode / SDK | Xcode 27.0 (27A5194q); macOS SDK 27.0 (26A5353p); selected developer `/Applications/Xcode-beta.app/Contents/Developer` |
| XcodeGen | 2.45.4; SHA-256 `3b483413a801394b00adb2fabf3c06ff8f800c73c8698e1f9a9d8a95d73939ef` |
| `xcresulttool` | `/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcresulttool`; SHA-256 `7aada4a60aad3de62bc7fbda7afd990e53d8335710d1a8792fd279d42491a5c9` |
| Machine | MacBookPro18,3, Apple M1 Pro, arm64, 8 physical/logical cores, 16 GiB RAM, AC power, no thermal warning at each accepted boundary |
| Fixture | `Fixtures/large-1mb.md`, 1,048,962 UTF-8 bytes, SHA-256 `d174f48ea6175db568abe44e5b71e82ee92f1cf9c0ed081d8f8308cc1961d247` |
| Historical measured capture helper | `docs/performance-evidence/editor-find-f2/2026-08-08-c871ddf5/reference/capture-editor-find-f2-authoritative-run.sh`; SHA-256 `c5f36fa61dc8cd3c9c465f61ec10695b3d21016bb16058f0ab66198f234597ef` |
| Historical measured exact-source runner | Same pack, `reference/run-editor-find-f2-performance-gate.sh`; SHA-256 `90e5aa9edd01a96132b80a092421c2cfc47c7e6d2944f1876bf8ddcf76edea8d` |
| Maintained tooling inventory | `Scripts/editor-find-f2-tooling.sha256`; SHA-256 `ab38b8068abfc03e063bce4208ce11aa96e0236eaf687b5e8014fdb2c4ce7974` |
| Maintained modular capture / exact-source runner | Thin wrappers SHA-256 `d188fcbd66a3c93907c0880bbe1cb94e15c09bbd0712d753d399334a41af285c` / `a5a05f706906f19c24fd3025cb7f387a41be7767a0e1b05b763139e837971340`; every sourced module is pinned by its wrapper and the tooling inventory |
| Maintained pack assembler | `Scripts/assemble-editor-find-f2-retained-evidence.py`; thin-wrapper SHA-256 `05f37034a892edd9d87481486e3a282f5582b03edb4263a0efc38816f5df4151`; module hashes are in the tooling inventory |
| Maintained retained-evidence checker | `Scripts/check-editor-find-f2-retained-evidence.py`; thin-wrapper SHA-256 `6b258d724a7a841b92b8f54cc5b53283d4b7bbf23eb2c1bc171520cd5927cc43`; module hashes are in the tooling inventory |
| Compact pack | `docs/performance-evidence/editor-find-f2/2026-08-08-c871ddf5`; `SHA256SUMS` SHA-256 `d2f1497b19c37db3b49b5028292871fe6194752d94de05f55d5e7b6337767e22` |
| Full owner-local root | `/Users/davis._.su/Documents/PlainsongPerformanceEvidence/editor-find-f2/2026-08-08-c871ddf.mYSJrs/authoritative-final-v2`; read-only; approximately 1.2 GiB; not externally replicated |

Current Python operator entry points require `/usr/bin/python3 -I`. Current maintained shell entry
points require an absolute entry-point path; direct execution supplies `bash -p` via the shebang,
while an explicit shell caller must use an allowlisted `env -i ... /bin/bash -p ABSOLUTE_PATH`
launcher. Maintained file digests use an empty environment and `/usr/bin/python3 -I -S`, not the
ambient-Perl `/usr/bin/shasum` path; executable/package paths reject non-owner or group/world-write
authority and ACL `allow` entries, while sealed input/output trees reject every ACL. In every case,
verify the tooling inventory and its pinned hash before execution. As with the owner-local evidence
itself, this trust root assumes files remain stable against a concurrent process already trusted as
the current UID between verification and pathname reopening; that same-UID boundary is explicit,
not a claim of race-proof loading.

Both builds retain source-archive SHA-256
`f0b84f1b43145b443364b28666710166debcd0c0342dad6e90092c2c70e55506` and pre-generation
source-tree SHA-256
`51b3c5309d67603ac8a4f298deed795d3c4afa597f0ac83cfcc3632e0abfda94`.
The Debug/Release generated build-input hashes are respectively
`2093bf7df313cc13ae24c964a6661ae05d15471547c553fc295003bbebeba3b6` and
`3b8012362941b304eb7d7812a8b6e3c9196b49555060af8164db4dadbe4f1fb6`.
Both resolved-package-input hashes are
`ed48178719a6c72d2880d3972e900d3bbe51f180d13e01dffd452de936f779c3`.
The Debug/Release build-manifest hashes are
`fe374662a09ccb452ce55f0796740c96b66624483afe55aa53fcff2c8dfb3510` and
`5ca8c353ad557267745566ec597ba5971b024afb2796237158b062e3fcdd6a8a`.

### Reproduction with fresh outputs

The measured build wrapper archives the `HEAD` of the checkout containing it. Running that wrapper
from this later documentation commit would therefore measure the wrong source. Start with a clean
detached worktree at the full measured commit, but invoke the exact retained historical capture
helper from a separate evidence checkout whose hash is verified. Allocate a new mode-0700 staging
root; never reuse any retained path. The immutable historical shell helpers predate the maintained
`bash -p` bootstrap, so the recipe launches them through an empty outer-shell allowlist that removes
inherited shell functions and `BASH_ENV` and supplies a fixed system-only `PATH`.

That outer launcher cannot retrofit isolated Python into immutable helpers: the historical build
and runner invoke Xcode's `/usr/bin/python3` without `-I`, and the runner recreates its own child
environment. The exact measured source tree prevents an untracked `Scripts/` shadow module, and the
recipe below requires the current user-site directory to be absent or empty, checks that every
existing directory from the user site to the canonical home is current-UID-owned and not
group/world-writable, rejects every access-control-list `allow` entry, and repeats that check before
every historical-helper invocation. This is a current-UID boundary, not protection against a
concurrent process already trusted as that same UID.
Xcode's system-site startup remains part of the selected historical toolchain and is not separately
hash-pinned by the retained checker. Treat any reproduction as a separately reported
historical-tool attempt, never as evidence produced by the current isolated maintained tooling.

```sh
set -euo pipefail
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1
export GIT_NO_REPLACE_OBJECTS=1

F2_MEASURED_COMMIT=c871ddf5c66c17f03fd9456b53f79411f9b2e979
F2_REPOSITORY_ROOT="$(/usr/bin/git --no-replace-objects rev-parse --show-toplevel)"
F2_EVIDENCE_CHECKOUT="$F2_REPOSITORY_ROOT"
F2_CAPTURE_REFERENCE="$F2_EVIDENCE_CHECKOUT/docs/performance-evidence/editor-find-f2/2026-08-08-c871ddf5/reference/capture-editor-find-f2-authoritative-run.sh"
F2_CAPTURE_SHA=c5f36fa61dc8cd3c9c465f61ec10695b3d21016bb16058f0ab66198f234597ef
F2_SOURCE_ARCHIVE_SHA=f0b84f1b43145b443364b28666710166debcd0c0342dad6e90092c2c70e55506
F2_SOURCE_TREE_SHA=51b3c5309d67603ac8a4f298deed795d3c4afa597f0ac83cfcc3632e0abfda94
F2_PACKAGE_INPUT_SHA=ed48178719a6c72d2880d3972e900d3bbe51f180d13e01dffd452de936f779c3
F2_DEBUG_BUILD_INPUT_SHA=2093bf7df313cc13ae24c964a6661ae05d15471547c553fc295003bbebeba3b6
F2_RELEASE_BUILD_INPUT_SHA=3b8012362941b304eb7d7812a8b6e3c9196b49555060af8164db4dadbe4f1fb6
F2_REPRO_ROOT="$(/usr/bin/mktemp -d /private/tmp/plainsong-f2-c871ddf-repro.XXXXXX)"
F2_SOURCE_WORKTREE="$F2_REPRO_ROOT/source"
F2_CAPTURE="$F2_REPRO_ROOT/historical-capture-helper.sh"
F2_RUNNER_USER="$(/usr/bin/id -un)"
F2_RUNNER_UID="$(/usr/bin/id -u)"
F2_RUNNER_HOME="$(
  /usr/bin/env -i LANG=C LC_ALL=C PATH=/usr/bin:/bin \
    /usr/bin/python3 -I -c \
    'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)'
)"
F2_HISTORICAL_USER_SITE="$(
  /usr/bin/env -i HOME="$F2_RUNNER_HOME" LANG=C LC_ALL=C PATH=/usr/bin:/bin \
    USER="$F2_RUNNER_USER" /usr/bin/python3 -I -c \
    'import site; print(site.getusersitepackages())'
)"

f2_sha256_file() {
  /usr/bin/env -i LANG=C LC_ALL=C PATH=/usr/bin:/bin \
    /usr/bin/python3 -I -S -c \
    'import hashlib, sys
digest = hashlib.sha256()
with open(sys.argv[1], "rb") as stream:
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        digest.update(chunk)
print(digest.hexdigest())' "$1"
}

test -n "$F2_RUNNER_USER"
case "$F2_RUNNER_UID" in
  ''|*[!0-9]*) exit 1 ;;
esac
case "$F2_RUNNER_HOME" in
  *$'\n'*|'') exit 1 ;;
  /*) ;;
  *) exit 1 ;;
esac
case "$F2_HISTORICAL_USER_SITE" in
  *$'\n'*) exit 1 ;;
  "$F2_RUNNER_HOME"/*) ;;
  *) exit 1 ;;
esac

f2_require_owner_controlled_directory() {
  F2_CONTROLLED_DIRECTORY="$1"
  test -d "$F2_CONTROLLED_DIRECTORY"
  test ! -L "$F2_CONTROLLED_DIRECTORY"
  test "$(builtin cd "$F2_CONTROLLED_DIRECTORY" && /bin/pwd -P)" = \
    "$F2_CONTROLLED_DIRECTORY"
  test "$(/usr/bin/stat -f '%u' "$F2_CONTROLLED_DIRECTORY")" = \
    "$F2_RUNNER_UID"
  F2_CONTROLLED_MODE="$(/usr/bin/stat -f '%Lp' "$F2_CONTROLLED_DIRECTORY")"
  case "$F2_CONTROLLED_MODE" in
    ''|*[!0-7]*|*[2367]?|*[2367]) exit 1 ;;
  esac
  if ! F2_CONTROLLED_ACL="$(
    LC_ALL=C /bin/ls -lde "$F2_CONTROLLED_DIRECTORY"
  )"; then
    echo "could not inspect historical Python user-site ACL boundary" >&2
    exit 1
  fi
  case "$F2_CONTROLLED_ACL" in
    *$'\n'*' allow '*) exit 1 ;;
  esac
}

f2_require_empty_historical_user_site() {
  F2_EXISTING_SITE_ANCESTOR="$F2_HISTORICAL_USER_SITE"
  while ! test -d "$F2_EXISTING_SITE_ANCESTOR"; do
    F2_NEXT_SITE_ANCESTOR="$(/usr/bin/dirname "$F2_EXISTING_SITE_ANCESTOR")"
    test "$F2_NEXT_SITE_ANCESTOR" != "$F2_EXISTING_SITE_ANCESTOR"
    F2_EXISTING_SITE_ANCESTOR="$F2_NEXT_SITE_ANCESTOR"
  done
  case "$F2_EXISTING_SITE_ANCESTOR" in
    "$F2_RUNNER_HOME"|"$F2_RUNNER_HOME"/*) ;;
    *) exit 1 ;;
  esac
  while :; do
    f2_require_owner_controlled_directory "$F2_EXISTING_SITE_ANCESTOR"
    test "$F2_EXISTING_SITE_ANCESTOR" != "$F2_RUNNER_HOME" || break
    F2_EXISTING_SITE_ANCESTOR="$(/usr/bin/dirname "$F2_EXISTING_SITE_ANCESTOR")"
  done
  if test -d "$F2_HISTORICAL_USER_SITE"; then
    if ! F2_USER_SITE_FIRST_ENTRY="$(
      /usr/bin/find "$F2_HISTORICAL_USER_SITE" -mindepth 1 -print -quit
    )"; then
      echo "could not inspect historical Python user site" >&2
      exit 1
    fi
    test -z "$F2_USER_SITE_FIRST_ENTRY"
  fi
}

f2_require_empty_historical_user_site

f2_clean_historical_bash() {
  /usr/bin/env -i \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_NO_REPLACE_OBJECTS=1 \
    HOME="$F2_RUNNER_HOME" \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    LOGNAME="$F2_RUNNER_USER" \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    TMPDIR=/private/tmp \
    USER="$F2_RUNNER_USER" \
    /bin/bash "$@"
}

test -f "$F2_CAPTURE_REFERENCE" && test ! -L "$F2_CAPTURE_REFERENCE"
test "$(f2_sha256_file "$F2_CAPTURE_REFERENCE")" = "$F2_CAPTURE_SHA"
test "$(/usr/bin/stat -f '%Lp' "$F2_REPRO_ROOT")" = 700
/bin/cp "$F2_CAPTURE_REFERENCE" "$F2_CAPTURE"
test "$(f2_sha256_file "$F2_CAPTURE")" = "$F2_CAPTURE_SHA"
/bin/chmod 400 "$F2_CAPTURE"
/usr/bin/git --no-replace-objects -C "$F2_REPOSITORY_ROOT" \
  cat-file -e "${F2_MEASURED_COMMIT}^{commit}"
/usr/bin/git --no-replace-objects -C "$F2_REPOSITORY_ROOT" \
  worktree add --detach "$F2_SOURCE_WORKTREE" "$F2_MEASURED_COMMIT"
test "$(/usr/bin/git --no-replace-objects -C "$F2_SOURCE_WORKTREE" rev-parse HEAD)" = \
  "$F2_MEASURED_COMMIT"
F2_SYMBOLIC_REF_STATUS=0
/usr/bin/git --no-replace-objects -C "$F2_SOURCE_WORKTREE" \
  symbolic-ref -q HEAD >/dev/null || F2_SYMBOLIC_REF_STATUS=$?
case "$F2_SYMBOLIC_REF_STATUS" in
  0)
    echo "F2 reproduction source must be detached" >&2
    exit 1
    ;;
  1) ;;
  *)
    echo "could not inspect F2 reproduction HEAD attachment" >&2
    exit 1
    ;;
esac
if ! F2_SOURCE_STATUS="$(
  /usr/bin/git --no-replace-objects -C "$F2_SOURCE_WORKTREE" \
    status --porcelain=v1 --untracked-files=all
)"; then
  echo "could not inspect F2 reproduction source status" >&2
  exit 1
fi
test -z "$F2_SOURCE_STATUS"

f2_require_empty_historical_user_site
f2_clean_historical_bash \
  "$F2_SOURCE_WORKTREE/Scripts/build-editor-find-f2-performance-gate.sh" \
  Debug "$F2_REPRO_ROOT/debug-build"
f2_require_empty_historical_user_site
f2_clean_historical_bash \
  "$F2_SOURCE_WORKTREE/Scripts/build-editor-find-f2-performance-gate.sh" \
  Release "$F2_REPRO_ROOT/release-build"

f2_manifest_value() {
  /usr/bin/awk -F= -v key="$1" \
    '$1 == key { value = substr($0, length($1) + 2); count += 1 }
     END { if (count != 1) exit 1; print value }' "$2"
}
F2_DEBUG_MANIFEST="$F2_REPRO_ROOT/debug-build/f2-editor-find-build-manifest.txt"
F2_RELEASE_MANIFEST="$F2_REPRO_ROOT/release-build/f2-editor-find-build-manifest.txt"
for F2_MANIFEST in "$F2_DEBUG_MANIFEST" "$F2_RELEASE_MANIFEST"; do
  test "$(f2_manifest_value source_commit "$F2_MANIFEST")" = "$F2_MEASURED_COMMIT"
  test "$(f2_manifest_value source_archive_sha256 "$F2_MANIFEST")" = \
    "$F2_SOURCE_ARCHIVE_SHA"
  test "$(f2_manifest_value source_tree_sha256 "$F2_MANIFEST")" = \
    "$F2_SOURCE_TREE_SHA"
  test "$(f2_manifest_value resolved_package_input_sha256 "$F2_MANIFEST")" = \
    "$F2_PACKAGE_INPUT_SHA"
done
test "$(f2_manifest_value configuration "$F2_DEBUG_MANIFEST")" = Debug
test "$(f2_manifest_value build_input_sha256 "$F2_DEBUG_MANIFEST")" = \
  "$F2_DEBUG_BUILD_INPUT_SHA"
test "$(f2_manifest_value configuration "$F2_RELEASE_MANIFEST")" = Release
test "$(f2_manifest_value build_input_sha256 "$F2_RELEASE_MANIFEST")" = \
  "$F2_RELEASE_BUILD_INPUT_SHA"

for F2_RUN in 1 2 3; do
  f2_require_empty_historical_user_site
  f2_clean_historical_bash \
    "$F2_CAPTURE" Debug "$F2_SOURCE_WORKTREE" "$F2_REPRO_ROOT/debug-build" \
    "$F2_REPRO_ROOT/debug-$F2_RUN"
done
for F2_RUN in 1 2 3; do
  f2_require_empty_historical_user_site
  f2_clean_historical_bash \
    "$F2_CAPTURE" Release "$F2_SOURCE_WORKTREE" "$F2_REPRO_ROOT/release-build" \
    "$F2_REPRO_ROOT/release-$F2_RUN"
done
```

Each new run is a separate reproduction attempt. Copy it to a newly allocated durable root before
staging cleanup, freeze a new compact inventory, and report its numbers separately. It must not be
mixed into this pack. A relevant source, fixture, dependency, XcodeGen, Xcode/SDK,
`xcresulttool`, macOS, machine, or capture-policy change invalidates this baseline and requires a
new six-run set; the checker enforces the identities recorded for this set but does not claim that
every future OS/toolchain change automatically fails before new evidence is assembled.

The current modular capture and runner are future maintained tooling and are **not** substituted
into the command above: these six artifacts were captured by the exact retained `c5f36fa…`
monolith, which in turn executed the exact `90e5aa9e…` runner in the detached measured source.
Likewise, the modular assembler is a baseline-specific resealer, not evidence that the original
runs used new tooling. It requires an explicit `--historical-capture-helper`, pins all historical
reference scripts/build manifests/tool identities, and refuses output unless the result is the
unchanged `d2f1497b…` pack. Its exact rebuild check may use still-present staging as an input, but
that staging is neither durable evidence nor required by the checker.
The pack's `commands.txt` is also immutable historical receipt text; the maintained operator audit
below supersedes its unqualified `python3` spelling and requires isolated `/usr/bin/python3 -I`.

Audit the retained pack with:

```sh
# Verify the current maintained operator trust root before importing/sourcing any module.
f2_sha256_file() {
  /usr/bin/env -i LANG=C LC_ALL=C PATH=/usr/bin:/bin \
    /usr/bin/python3 -I -S -c \
    'import hashlib, sys
digest = hashlib.sha256()
with open(sys.argv[1], "rb") as stream:
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        digest.update(chunk)
print(digest.hexdigest())' "$1"
}
f2_require_trusted_tool_path() {
  F2_TOOL_PATH="$1"
  test -f "$F2_TOOL_PATH" && test ! -L "$F2_TOOL_PATH" || return 1
  test "$(/usr/bin/stat -f '%u' "$F2_TOOL_PATH")" = "$(/usr/bin/id -u)" || return 1
  F2_TOOL_MODE="$(/usr/bin/stat -f '%Lp' "$F2_TOOL_PATH")" || return 1
  case "$F2_TOOL_MODE" in
    ''|*[!0-7]*|*[2367]?|*[2367]) return 1 ;;
  esac
  if ! F2_TOOL_ACL="$(
    /usr/bin/find "$F2_TOOL_PATH" -maxdepth 0 -acl -print
  )"; then
    return 1
  fi
  test -z "$F2_TOOL_ACL"
}
test "$(f2_sha256_file Scripts/editor-find-f2-tooling.sha256)" = \
  ab38b8068abfc03e063bce4208ce11aa96e0236eaf687b5e8014fdb2c4ce7974
f2_require_trusted_tool_path Scripts/editor-find-f2-tooling.sha256 || exit 1
while read -r F2_TOOL_DIGEST F2_TOOL_PATH; do
  [[ "$F2_TOOL_DIGEST" =~ ^[0-9a-f]{64}$ ]] || exit 1
  f2_require_trusted_tool_path "$F2_TOOL_PATH" || exit 1
done < Scripts/editor-find-f2-tooling.sha256
/usr/bin/env -i LANG=C LC_ALL=C PATH=/usr/bin:/bin \
  /usr/bin/shasum -a 256 -c Scripts/editor-find-f2-tooling.sha256

# Compact records only: prints PARTIAL/OPEN and exits 3 by default.
test "$(f2_sha256_file Scripts/check-editor-find-f2-retained-evidence.py)" = \
  6b258d724a7a841b92b8f54cc5b53283d4b7bbf23eb2c1bc171520cd5927cc43
/usr/bin/python3 -I Scripts/check-editor-find-f2-retained-evidence.py \
  docs/performance-evidence/editor-find-f2/2026-08-08-c871ddf5

# Explicitly accept the limited compact audit: still prints PARTIAL/OPEN.
/usr/bin/python3 -I Scripts/check-editor-find-f2-retained-evidence.py \
  docs/performance-evidence/editor-find-f2/2026-08-08-c871ddf5 --allow-partial

# Current owner-local full audit: prints proxy/warning PASS while the root exists.
/usr/bin/python3 -I Scripts/check-editor-find-f2-retained-evidence.py \
  docs/performance-evidence/editor-find-f2/2026-08-08-c871ddf5 \
  --artifact-root \
  /Users/davis._.su/Documents/PlainsongPerformanceEvidence/editor-find-f2/2026-08-08-c871ddf.mYSJrs/authoritative-final-v2
```

### Procedure and measured boundary

The query clock starts immediately before `AppState.handleEditorFindQueryTextChange`. It includes
App query publication, the production 150 ms debounce, detached `TextSearchEngine` matching,
revision/query fencing, main-actor session application, and App presentation. Each deterministic
scenario gets one unmeasured warm-up and three measured samples. Every sample hard-asserts the
fixture identity, retained/truncated shape, exact endpoint positions, and off-main matcher receipt.

| Shape | Query | Expected result | Exact retained endpoints |
|---|---|---|---|
| Zero | `plainsong-f2-zero-hit` | 0 retained; not truncated | first/last `nil` |
| Sparse | `generated sections: 1274` | 1 retained; not truncated | first = last: location 1,048,904, length 24, line 33,140 |
| Dense | `section` | 10,000 retained; truncated by overflow 10,001 | first: location 399, length 7, line 15; last: location 914,752, length 7, line 28,901 |

The hosted probe mounts the shipped `WorkspaceWindow` with real observed `AppState`, the public
editor, and the shipped `EditorFindBar`. It opens find, primes the dense query, verifies visible
`1 / 10000+`, then performs five native `insertText` edits. Admission ends when `insertText`
returns. Root receipt ends when the test-only root representable enters its update transaction with
the new revision, query/bar still present, and old find presentation invalidated. It does not
require child layout or compositor presentation and includes no physical keyboard delivery.
Therefore neither proxy proves the product `<16 ms` keystroke-to-screen criterion.

The capture helper records clean/AC/no-thermal preflight and postflight boundaries and waits 200 ms
after each completed scan of the target process set. It retains every sample plus every exemption attributable by
runner ancestry, exact private host path, or a token-bound private output prefix. The checker
rejects exemptions at or after the runner-finished sample. This proves no *sampled* uncorrelated
target process during accepted intervals; it does not claim continuous absence between samples.

For non-authoritative operator context, one attempted Debug 3 run was rejected after the monitor
observed nine foreign monitored-process records: five `swift-frontend` and four `xctest` records
across five unique PIDs. That rejected attempt remains only in the `/private/tmp` staging area and
is not part of either retained evidence copy. A fresh-prefix retry began only after those processes
ended. Accepted run sample/owned-record counts were respectively
74/33, 74/33, 77/34, 61/18, 61/17, and 61/19, with zero uncorrelated matches in every accepted run.

### Exact raw measurements

All values are milliseconds. Bold is the median within the displayed sample array.

| Configuration / run | Zero samples; median | Sparse samples; median | Dense samples; median |
|---|---|---|---|
| Debug 1 | `[241.020, 223.153, 247.238]`; **241.020** | `[259.014, 250.378, 239.762]`; **250.378** | `[580.960, 580.041, 585.822]`; **580.960** |
| Debug 2 | `[235.082, 245.107, 231.740]`; **235.082** | `[255.892, 232.944, 254.619]`; **254.619** | `[591.634, 600.164, 587.173]`; **591.634** |
| Debug 3 | `[226.407, 241.879, 229.118]`; **229.118** | `[256.710, 241.698, 271.743]`; **256.710** | `[601.683, 607.733, 575.622]`; **601.683** |
| Release 1 | `[171.100, 174.493, 178.240]`; **174.493** | `[186.542, 192.538, 184.102]`; **186.542** | `[235.831, 243.462, 237.281]`; **237.281** |
| Release 2 | `[170.424, 171.058, 171.917]`; **171.058** | `[192.345, 189.156, 194.835]`; **192.345** | `[245.958, 221.562, 253.468]`; **245.958** |
| Release 3 | `[177.752, 170.781, 165.903]`; **170.781** | `[181.082, 188.834, 181.319]`; **181.319** | `[215.846, 260.129, 233.066]`; **233.066** |

| Configuration / run | Admission samples; median | Root receipt samples; median; maximum |
|---|---|---|
| Debug 1 | `[1.091, 0.995, 15.802, 1.098, 1.017]`; **1.091** | `[4.535, 3.599, 18.454, 3.825, 3.625]`; **3.825**; max **18.454** |
| Debug 2 | `[1.119, 1.051, 15.787, 1.042, 0.953]`; **1.051** | `[4.568, 3.732, 18.667, 3.759, 3.506]`; **3.759**; max **18.667** |
| Debug 3 | `[1.129, 1.062, 15.974, 1.171, 1.021]`; **1.129** | `[4.452, 3.715, 18.839, 4.259, 3.661]`; **4.259**; max **18.839** |
| Release 1 | `[1.148, 1.015, 14.057, 0.993, 0.867]`; **1.015** | `[4.738, 4.016, 17.016, 4.252, 3.623]`; **4.252**; max **17.016** |
| Release 2 | `[1.132, 0.904, 13.466, 0.937, 0.839]`; **0.937** | `[4.775, 3.282, 16.473, 3.355, 2.990]`; **3.355**; max **16.473** |
| Release 3 | `[1.250, 1.036, 13.521, 1.039, 0.866]`; **1.039** | `[4.797, 3.745, 16.199, 3.791, 3.377]`; **3.791**; max **16.199** |

The repeated third-edit tail remains visible rather than prewarmed away. It is the existing
main-actor `EditorScrollLineIndex` rebuild after scroll-sync cache invalidation, not in-document
matching. Its presence is another reason not to reinterpret median admission as full screen
latency.

### Budgets and medians

The existing 400 / 400 / 1,100 / 5 / 15 ms local-hard ceilings were not widened. They were derived
from earlier Debug measurements and now have the following measured headroom over the slowest new
Debug run median. Release is confirmation only. On CI, wall-clock treatment remains informational
under R15; fixture, result shape, warning phase, source identity, and state invariants remain hard.

| Metric | Debug run medians | Debug median of run medians | Release run medians | Release median of run medians | Budget | Budget / slowest Debug median |
|---|---|---:|---|---:|---:|---:|
| Zero query completion | 241.020, 235.082, 229.118 | **235.082** | 174.493, 171.058, 170.781 | **171.058** | < 400 | 1.66x |
| Sparse query completion | 250.378, 254.619, 256.710 | **254.619** | 186.542, 192.345, 181.319 | **186.542** | < 400 | 1.56x |
| Dense-truncated query completion | 580.960, 591.634, 601.683 | **591.634** | 237.281, 245.958, 233.066 | **237.281** | < 1,100 | 1.83x |
| Native edit admission | 1.091, 1.051, 1.129 | **1.091** | 1.015, 0.937, 1.039 | **1.015** | < 5 | 4.43x |
| Root state-update receipt | 3.825, 3.759, 4.259 | **3.825** | 4.252, 3.355, 3.791 | **3.791** | < 15 | 3.52x |

### Frozen run identities and warning phase

| Run | Raw log SHA-256 | Raw xcresult SHA-256 | Inspection xcresult SHA-256 | Warning phase UUID |
|---|---|---|---|---|
| Debug 1 | `7f5b2555b869eb4272f3b41e682d3b58fb4d1f9d736cf28f74d08a19f10c9c87` | `2a36f1f0f1552e8405aea6a9c6e37cedb7aeed25c1468b2fcc31a17c59025d36` | `2e0b3ba8fda4525f84f87e9f221dca3b5c9b9155ce93da1f25d72f3743f81b1c` | `b8bd411a-f084-4bd6-96d7-f3c9643e0932` |
| Debug 2 | `f423e80f01fe3358e4f8c74937af32234e348a9118c3e773746ddcaa54fa295b` | `a743d37e8af25036b53b1a02daa54785d15313d2115a1de821fa070b8a84ffab` | `5482591b7c99424c3bb480a8f03d8b8a12768a92c7f85840578c6902a247d9a3` | `3b3ad8c9-2487-4ae7-ae91-a037344d058b` |
| Debug 3 | `b97bf3663dbc79316c3312b6238736e3bf7a33e8960985dee38b4da2547e5507` | `4b64721255085afbfbc5cf2365c7f1824b7195ee9c766e837f600b8a45841bdb` | `6bac0e9446f10eeec09896dae932a942e26a9a88f5f8d6ce6f68353e7e48b4f9` | `bc493029-237a-4438-af59-c778f4f294f6` |
| Release 1 | `7b2320385c7f5293fe81f3b8a481c17a577d4a6739b44595867c23ce09aaa771` | `8e4a78681a1ca1f0e6f214a137deeab5c2ae18ffbb01876f4fbd57b74cf2826f` | `0a1a5dc3f4e5d587677089461f07ada1a957182ef74c1135d0fd3145cab8409b` | `6c68a1f6-7cd6-4b19-9959-40ddab397737` |
| Release 2 | `307ca9866fb40f9942b80db59617d6f7dd68e570a77207ba496228ed936918f3` | `d400fa26d00c67ecd8ffff56b7288a303f4e9cfee769015f4c0a8f9103d430b0` | `466aa01922200f8677810398857fcfcdba769f0c6cbce89e1ada00a6e0e0294e` | `c6abf3b0-a1e3-49cd-829a-d15fd49c9d99` |
| Release 3 | `50be75593b20576ce8fad502328b87fb936c6142ee31baee14d58989fa5094f1` | `07c2b39e2d93a1b09dce353acac815328cee0bb4b44b3e328efc46ccdbc53e59` | `f212519e07cf8e6ff3f480babe47f43d6184d9c69d8f58dff780f53b841dad28` | `6b3b97ed-37c5-4fc5-b24f-34e6ddb464e9` |

Every accepted raw log has exactly three known SwiftUI warnings before its same-UUID
`F2_WARNING_PHASE_BEGIN`, zero during the five edits, zero after `END`, and no unknown SwiftUI
warning. Each xcresult coalesces the three emissions into one known Runtime Warning issue. The
existing negative control moves one warning inside the interval and must exit 1 even though the
coalesced issue stays one. The full retained audit rechecks the raw phase, the negative control,
the frozen result bundles, and a fresh summary from a disposable copy.

This is a narrow exception, not warning-free evidence. A warning during a measured edit fails; a
signature/count change also fails the frozen baseline. The pre-measure warnings remain in the
pre-F2 selection-binding/navigation path. F8-owned production files were not modified here.

### F8 and full-product boundary

Measured commit `c871ddf` has no production highlight-all apply/clear surface. The fixture,
deterministic scenarios, production host, and generation-stamped receipt can be reused after F8
lands, but no apply, clear, preservation, physical-input, screen-presentation, F9, or combined-tip
evidence is claimed here.

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
