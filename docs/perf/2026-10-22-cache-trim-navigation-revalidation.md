# Intermittent hosted typing slowdown: revalidate every element-cache trim

- Date: 2026-10-22
- Commit: fix `73adc68cd3535a92e0f267cc3389173beb9d7c69` (F, #197) against #189 head
  `808190415ec80fa30acb0c81e206025343349177` (H) and main
  `2138165e703644f87494518fb113e11f5dcc04e1` (M, #189's pinned base then)
- Environment: macOS 27.0 (26A428), Xcode 27.0 (27A5194q), STTextView 2.4.1, Apple M1
  Pro 8 cores 16 GiB; optimized Debug (`SWIFT_OPTIMIZATION_LEVEL=-O`,
  `GCC_OPTIMIZATION_LEVEL=s`), serialized under `/private/tmp/plainsong-xcodebuild-test.lock`;
  1-minute load 5.30–32.22 at run start/end, no idle-machine gate, screen unlocked
- Fixture: `Fixtures/large-1mb.md` (1,048,962 UTF-16 units); agent.md §12 typing latency
- Procedure: the app-hosted source-only busy-slice probe
  `EditorFindHostedGateTests/testHostedSourceOnlyTypingMainThreadBusySlices`
  (`TEST_RUNNER_PLAINSONG_RUN_SCROLL_PROBE=1`, line numbers on, 30 trim chunks, scroll
  after chunk 16, 1 ms yields, admission replay on), 50 native insertions plus the main
  run-loop work they schedule. Five interleaved H/F/M triplets in the orders HFM, FMH,
  MHF, HMF, FHM. The exact build and test commands are in the evidence pack's original
  README, linked under Evidence below.
- Result: median run busy H 2,122.1 ms, F 2,079.2 ms, M 3,476.8 ms. F is 38.5–46.9%
  below M in every pair. The one slow H run (H4, 4,932.9 ms, 40.25 ms insertion median)
  has no slow F counterpart (F4 2,149.8 ms, 6.23 ms). No absolute budget is claimed.

PR #189's intermittent slowdown is reproducible with a controlled interrupted trim. The
repair is in `EditorTextElementCacheTrimmer`, with selection-based rescheduling in the
coordinator; it keeps #189's EditorKit gutter. Design:
[`docs/decisions/2026-10-22-revalidate-cache-trim-navigation.md`](../decisions/2026-10-22-revalidate-cache-trim-navigation.md).

## Reproduction and mechanism

Walk backward from the end of `large-1mb.md` in 32,768-unit trim candidates. After chunk
16, move the caret to 524,480 and scroll it into view, settle 10 ms, then continue with
1 ms yields and a gutter draw after each trim. This fixes the navigation/trim ordering
and the requested ranges. Native AppKit display scheduling still decides whether the
full slow layout trajectory persists into typing, so the timing outcome is not
deterministic. The production-loop regression tests assert the safety invariant at that
navigation boundary deterministically.

The old seventeenth chunk `[491906,524674)` discards the selected paragraph
`[524480,524488)`. The eighteenth, `[459138,491906)`, also discards the new native
viewport, `[460354,461927)` in run H4. Cancellation after a new visible-range report can
arrive after these attribute edits. Cumulative trim counters count requested ranges, not
cached-element inventory; the explicit replay calls the static trim and records its own
ranges without incrementing the instance counter.

H4 starts at height 882,743.5 with a 1,575-unit viewport. Native relocation shrinks the
frame to 349,673.33 and clamps the clip position; the viewport then jumps through offset
23,177 and reaches 901,107 at key 5. That key recreates **10,896 paragraphs through
offset 903,133**. The captured threshold stack is `NSTextContentStorage` →
`NSTextLayoutManager.enumerateTextLayoutFragments` →
`NSTextViewportLayoutController.layoutViewport` → `STTextView.layoutViewport/layout` →
AppKit display. Later insertions stay expensive (40.25 ms run median, 76.99 ms maximum)
while requesting one new paragraph each, which matches the cached-suffix range-update
cost identified in #180. No trim runs during typing. Gutter drawing totals 15.32 ms,
with no width changes or line-index rebuilds.

Fresh admission checks the real nonempty native viewport immediately before each
attribute edit, and separately protects whole selected paragraphs with an 8,192-unit
margin. It shortens or skips unsafe candidates and advances from the returned location.
F4 redirects the offending candidates to `[483520,516288)` and `[470119,483520)`, then
stops: 18 ranges instead of 30. All **90/90** final F ranges are bounded, descending and
disjoint from the live viewport prefix/prefetch and the selected-paragraph band; all 390
H/F/M ranges have same-main-actor-turn before-state captures. Every H/M replay includes
the old post-navigation collisions. F still allows native height and clip adjustments;
it avoids destroying the live elements and the distant tail refill, not all resizing.

A matched-width gutter-off reference also reproduced 5,325 ms / 46.40 ms insertion
median, and hiding drawing early reproduced a slow run too. A gutter snapshot candidate
that avoided draw-time TextKit enumeration still reproduced 5,299 ms. Neither draw-time
enumeration nor `needsDisplay` alone is necessary for the slow mode. Earlier main
formation controls stayed fast, and final M4 has stale collisions without H4's tail
fill. The changed gutter geometry and cache history appear to expose the pre-existing
#180 stale-task race; that frequency explanation is an inference. **This does not
exonerate #189.** The snapshot and native-height adapters were rejected, and an earlier
suffix-only guard was superseded because it missed native viewport absence and blocked
useful trimming before an offscreen end caret. Those cohorts stay separate in the
evidence.

## Final interleaved comparison

All three use the same fixture, source-only layout, line numbers on, and a 1,000 pt
window with a 408 pt text container. M's native gutter leaves a 459 pt clip/text-view
width; H/F's separate gutter leaves 408 pt. The H and M overlays only add equivalent
diagnostics and a test-only identity `protectedChunk`, so they keep the old admission
policy; their production coordinator and admission code are unchanged. The F replay
calls the production interval planner; scheduled-loop tests cover its task integration
separately. Executable, test-bundle, fixture and source hashes, the toolchain and both
baseline overlay patches are bound in the final build manifest.

| Round / order | H busy ms / insertion median ms | F busy ms / insertion median ms | M busy ms / insertion median ms | F − H busy |
|---|---:|---:|---:|---:|
| 1 / HFM | 2,080.9 / 5.47 | 1,966.4 / 5.80 | 3,440.8 / 5.75 | -5.50% |
| 2 / FMH | 2,165.5 / 6.03 | 2,131.8 / 5.71 | 3,476.8 / 5.81 | -1.56% |
| 3 / MHF | 2,122.1 / 5.98 | 2,079.2 / 5.99 | 3,459.7 / 5.70 | -2.02% |
| 4 / HMF | 4,932.9 / 40.25 | 2,149.8 / 6.23 | 3,498.4 / 5.35 | -56.42% |
| 5 / FHM | 1,974.8 / 5.76 | 1,995.0 / 5.79 | 3,757.0 / 6.00 | +1.03% |

Busy time includes scheduled main-thread work; the insertion duration covers only the
synchronous `insertText` call. Each run is the comparison unit, not its 50 keys. Against
ordinary fast H runs, busy changes range from −5.50% to +1.03% and insertion-median
differences from −0.321 to +0.326 ms; keep the +20.25 ms round-5 result rather than
calling every H comparison faster. The slow H4 pair improves 56.42% busy and 84.5%
insertion median, and F4 stays fast at load 25.99→30.95. H has one ≥10,000-paragraph
refill in five runs; F and M have none. F's peak is 1,474 paragraphs in every run.

Load is recorded inside the admitted lock and includes other user work and a serialized
package-check interval. These five runs demonstrate the controlled mechanism and a
recorded-load comparison. They do not establish a zero future slow-run rate, idle
acceptance or screen-to-photon latency.

## Local validation of `73adc68`

- EditorKit Debug: 513 tests, 8 existing opt-in skips, 0 failures. The 13 focused
  trimmer/coordinator tests pass; substituting the old production trimmer and
  coordinator produces 40 failing assertions across them. Cases include navigation
  during a scheduled pass, selection changes between chunks, old end-caret/top-scroll
  trimming, long paragraphs, missing native viewports, Select All collapse without
  scrolling and duplicate-notification timer liveness.
- MarkdownCore 323, PreviewKit 133, WorkspaceKit 371 tests, 0 failures. F2 tooling 86
  tests and inventory pass; both sandbox probes pass.
- Preview: 21 files / 150 tests passed. No preview sources changed.
- App-hosted XCTest on the same optimized F binaries (`test-without-building`,
  `TEST_RUNNER_CI=1`): PlainsongTests 976 (16 opt-in skips) and PerformanceTests 30
  (4 skips), 0 failures. PlainsongUITests was not run locally.
- Pinned SwiftFormat 0.62.1 `make format` and `make lint`: 0/708 files need formatting,
  0 serious violations; two new size warnings (a 53-line admission function and a
  340-line test class).
- A full optimized SwiftPM Release attempt hit existing IME deferred-install fixtures
  that assume progress after 16 `Task.yield` calls, and one then indexes an empty array.
  The old production baseline reproduces six assertions in the two focused Release
  controls. This is not a green Release-package result.

Maintainer manual and IME testing of #189 remain separate; this entry does not claim
them.

## Evidence

[`docs/evidence/gutter-slow-run-20261022/README.md`](../evidence/gutter-slow-run-20261022/README.md)
links every retained file (final runs, per-key mechanism and range checks, build
manifests, overlays, scripts, `validation.json`) at commit
`5a5f3b52eda1f063fd32fe7dd821db425ac4367d`, where they remain after leaving the tree.
The raw reports, logs and result bundles were never committed; they stayed on the
measuring Mac under `/private/tmp/plainsong-gutter-slow-evidence` and the three recorded
DerivedData paths, with digests in `raw-manifest.json`.
