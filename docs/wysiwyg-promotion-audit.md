# WYSIWYG Stable-Promotion Audit — 2026-10-24

Re-verification of every gate in `docs/wysiwyg-release-checklist.md` (A, B1-B13, C, D),
`docs/image-thumbnail-gates.md` (I0-I10) and `docs/link-folding-gates.md` (L1-L9) against
`origin/main` `1428bf1`, before the D.4 promotion. Most evidence dates from June-July;
the editor changed a lot since. This audit asks, per gate: does the cited evidence still
run, does it still pass, and could a later change have invalidated it?

**Result:** every automated gate still passes. Two blockers remain: the click-layout fix
(no PR yet) and the owner's dogfood sign-off (`docs/wysiwyg-dogfood-checklist.md`), which
includes the owner-run actual-IME harness. No WYSIWYG product bug was found. Four test
gaps were closed with new tests and one perf record.

## What changed since the evidence

| Change | Could affect | Checked by |
|---|---|---|
| STTextView 2.3.10 → 2.4.1 (#180): viewport extends up to half a screen above the visible area; layout sizing reworked; default paragraph style now stamped on existing text | Pointer hit-testing, geometry (B13), visible-range cost (B10/L8/I8), IME | All pointer/geometry gates rerun; new production-viewport perf gate; `STTextView+NSTextInputClient.swift` is unchanged between the two tags (the diff is layout, sizing, gutter, completion, mark commands, paragraph style) |
| Typing path (#180): `isInstalled` no longer treats `nil === nil` as installed | Source-only invariant A.3, WYSIWYG enable/disable | `WYSIWYGNativeInteractionGateTests.testDisablingFoldingThatWasNeverEnabledDoesNotTreatNilAsInstalled` and the delegate-forwarding tests pass |
| Visible-top scroll sync (#185, squashed into #180) | Source+preview only | Not WYSIWYG-reachable; covered by the preview/scroll suites in CI |
| EditorKit-owned line-number gutter (#189) | Pointer x-offset in the WYSIWYG hit-test, which subtracts STTextView's own `gutterView` | New `WYSIWYGLineNumberGutterPointerGateTests` |
| Element-cache trimming with revalidation (#180, #197 squashed into #189) | Attribute-only edits make TextKit drop paragraphs the zero-width projection built | New `WYSIWYGElementCacheTrimGateTests` |
| Whole-source assignment resets (#154) | Image markers and folds after App text replacement | Hosted `testHostedSameLength*RestoresImageThumbnailAndFoldsWithoutAnEdit` (3) pass |
| Replace/Find (#145/#151) | WYSIWYG Replace authority, presentation recovery | `EditorReplaceWYSIWYGTests` (17), batch WYSIWYG recovery (2) and 13 hosted Replace/Keep Mine WYSIWYG tests pass |
| iOS integration (#188): fold model and parser moved to `SyntaxKit`; EditorKit keeps typealiases | Every fold/reveal gate | EditorKit gate tests now exercise the SyntaxKit code through those aliases; `WYSIWYGFoldModelTests` (14) pass |

## How it was run

- `cd Packages/EditorKit && swift test` (full suite): 516 tests, 8 opt-in skips, 1 failure
  (L8 at load 85-106; see B10/L8 below). Every other WYSIWYG class passed.
- `swift test --filter` for the cited MarkdownCore (`MarkdownImageRegionsTests`, 5) and
  WorkspaceKit (`WorkspaceImageThumbnailProviderTests`, 9 cited) tests: all pass.
  `cd Packages/SyntaxKit && swift test` (the fold model's new home): 12 tests pass.
- Hosted, PlainsongTests only (never PlainsongUITests), screen locked, on `04e37fa`
  (main + test-only commits): `AppStateTests` 175 passed, 1 skip (case-sensitive volume);
  19 WYSIWYG methods of `EditorFindHostedGateTests` 16 passed, 3 opt-in skips (two
  typing probes, one stress run).
- Hosted again with the promotion changes: `AppStateTests`, `WYSIWYGPromotionAppStateTests`,
  `MenuBarStateTests` and the same 19 methods: 200 executed, 196 passed, 4 opt-in skips,
  0 failures.
- Perf reruns: `docs/perf/2026-10-24-wysiwyg-promotion-gates.md`.
- Not run locally: full `make test` (it includes PlainsongUITests, which kill a running
  Plainsong), PreviewKit and preview-src (no WYSIWYG code path), and the opt-in
  actual-IME harness (owner-run; it switches the system input source). CI runs the first
  two on this PR.

## A. Mechanism

| Gate | Evidence rerun | Invalidated by a later change? | Status |
|---|---|---|---|
| A.3 Source canonicality | `testProductionFoldPresentationCopyUsesRawBackingString`, `testAccessibilityValueRemainsRawMarkdownSource`, `testPasteIntoFoldedAndRevealedRegionsMutatesBackingSourceOnly` pass | Cache trimming edits attributes below the viewport: new trim gate proves text and fold attributes stay identical | Holds |
| A.3 Geometry sanity | B13 passes | STTextView 2.4 layout sizing: B13 still passes | Holds |
| A.3 Source-only unchanged | Evidence was `make test` (2026-06-26). Rerun: full EditorKit, AppStateTests, hosted source-mode Replace/Keep Mine tests | #180 fixed a source-mode path that invalidated the whole layout on every keystroke (performance, not text) | Holds; full suite is CI's |
| A.3 Source+preview unchanged | Not WYSIWYG-reachable | #185 is source+preview only | CI |
| A.3 Attribute compatibility | `testDevelopmentInlineFoldRevealFoldsIncludedConstructsAndDefersLinks`, `testPartialHighlightApplyPreservesTextAndSelection` pass | Highlight apply now skips equal runs (still the same stored result) | Holds |
| A.3 No undo pollution | `testAttributeOnlyPresentationDoesNotEnterUndoOrRedoStack`, `testWYSIWYGUndoRecomputesFoldRevealStateWithoutUndoingPresentation` pass; trim gate checks Undo | — | Holds |
| A.4 Mechanism decision | Content-storage projection unchanged; STTextView 2.4.1 still owns the layout-manager delegate | Doc comments still called it a "non-user-facing development hook": fixed in three files | Holds |

## B. Gate-rerun matrix

| # | Evidence rerun | Invalidated by a later change? | Status |
|---|---|---|---|
| B1 Zhuyin | Opt-in, skipped by default. Deterministic marked-text coverage passes: `WYSIWYGIMESpikeTests` (4), `testTrimIsRefusedDuringMarkedTextComposition`, the gutter keeps its width during marked text | STTextView 2.4.1 did not change `NSTextInputClient`, but the last real-IME run (2026-07-12) predates it, #180's typing changes and #189 | **Owner rerun required** (R9) |
| B2 Pinyin | Same | Same | **Owner rerun required** |
| B3 Arrow near folds | Both cited tests pass | — | Holds |
| B4 Reverse shift-selection | Both cited tests pass | — | Holds |
| B5 Pointer click | Three cited tests pass; new gutter-visible test passes | Every pointer click lays out the whole document (`ensureLayout(documentRange)` in the hit-test) | Holds; rerun after the click-layout PR |
| B6 Pointer drag | Passes | Same hit-test | Holds; rerun after the click-layout PR |
| B7 Raw copy | Both cited tests pass | — | Holds |
| B8 Paste | Passes | — | Holds |
| B9 AX value | Passes | — | Holds |
| B10 Visible-range perf | 24.8-27.6 ms over 3 isolated runs (was 26.964 ms) | The gate times one line; production requests the whole padded viewport, which STTextView 2.4 made taller. New production-viewport gate: 27.2-30.0 ms over a 6,324-unit request | Holds |
| B11 Undo/redo | Both cited tests pass | — | Holds |
| B12 Source regression | See "How it was run" | `make test` now includes PlainsongUITests, which this audit must not run | Holds locally; full suite is CI's |
| B13 Geometry | Passes | — | Holds |

## C. UX policy

| Gate | Evidence rerun | Status |
|---|---|---|
| C.1 Reveal timing | B10 and the production-viewport gate under budget; selection-driven reparse covered by the hosted Replace/Keep Mine tests | Holds; dogfood §2 rechecks the feel |
| C.2 Edge snapping | `WYSIWYGEdgeSnappingGateTests`: all 17 pass, including the 10 cited | Holds; pointer rows rerun after the click-layout PR |
| C.3 Selection on delimiters | Cited tests pass; `EditorInteractionRegressionTests` 9/9 | Holds |
| C.4 Copy policy | Cited tests pass | Holds |
| C.5 Link folding | L1-L9 below; the owner IME run is from 2026-07-06 | Holds; owner IME rerun required |

## D. Mode integration

| Gate | Evidence rerun | Status |
|---|---|---|
| D.1 `⌘⇧P` cycle | Enabled/disabled cycle and mechanism-failure tests pass on main. The 2026-06-27 manual label check used labels this PR changes | Holds; dogfood §9 rechecks labels |
| D.2 Persisted enum + migration | Both migration tests and the persistence test pass. The persistence test toggled source only → source + preview, which assumed the off default; it now walks source only → WYSIWYG → source + preview | Holds |
| D.3 Kill switch + recovery | Pass. The Settings switch stays as the kill switch, now on by default; an opt-out stored before the promotion is kept (`WYSIWYGPromotionAppStateTests`) | Holds |
| D.4 Labeling | First two boxes are true of main. The third is this PR, pending sign-off | Open |

## E. Construct scope

Unchanged: this PR adds no construct. Reference links, autolinks, ineligible and
single-file images, fenced code, tables, Mermaid/math and MDX stay raw (`testL1ReferenceLinksAutolinksAndImagesStayRaw`,
`testI1ReferenceAutolinkEmptySourceAndMalformedFormsDoNotEmitImageRegions`,
`testSingleFileModeProvablyKeepsImageThumbnailsRawAtAppBoundary` pass).

## Image thumbnails I0-I10

| Gate | Evidence rerun | Status |
|---|---|---|
| I0 Mechanism | `WYSIWYGImageThumbnailPresentationTests` (21, incl. the #80 raw-copy/AX/undo invariants) pass | Holds |
| I1 Model | 5 MarkdownCore + 3 EditorKit cited tests pass | Holds |
| I2 Render policy | 4 WorkspaceKit loader tests, the presentation/render-policy tests and hosted `testWorkspaceReloadInvalidatesOnlyChangedAllowlistedRasterPaths` pass; #154 same-length reload tests pass | Holds |
| I3 Caret/selection | 7 cited tests pass | Holds |
| I4 Copy/paste | 2 cited tests pass | Holds |
| I5 IME | Opt-in; last owner run 2026-07-12 | **Owner rerun required** |
| I6 Pointer | 4 cited tests pass | Holds; rerun after the click-layout PR |
| I7 AX | 3 cited tests pass | Holds |
| I8 Perf/memory | 16.2-17.3 ms over 3 runs (was 15.234 ms); in-flight typing, off-main decode, 32 MiB cache tests pass | Holds |
| I9 Undo/redo | 3 cited tests pass | Holds |
| I10 Security | 5 WorkspaceKit cited tests pass | Holds |

## Link folding L1-L9

| Gate | Evidence rerun | Status |
|---|---|---|
| L1 Model | 3 cited tests pass | Holds |
| L2 Styling/pointer policy | Passes; the Decision Log policy is unchanged | Holds |
| L3 Destination-edge snapping | 3 cited tests pass | Holds |
| L4 Copy/paste | 2 cited tests pass | Holds |
| L5 IME | Opt-in; last owner run 2026-07-06 | **Owner rerun required** |
| L6 Pointer | 2 cited tests pass | Holds; rerun after the click-layout PR |
| L7 AX | Passes | Holds |
| L8 Perf | Failed once at 159.651 ms in the full suite at load 85-106 (the other samples were 24 and 30 ms); 15.6-16.0 ms over 3 isolated runs at load 12-14 (was 16.968 ms) | Holds (contention, R15) |
| L9 Undo/redo | Passes | Holds |

## Findings and what this PR did

1. **Cache trimming was untested under WYSIWYG.** Added
   `WYSIWYGElementCacheTrimGateTests`: a trim keeps text, fold attributes, selection,
   scroll and Undo, and a trimmed paragraph is rebuilt by the projection with its `**`
   and hidden link destination still zero width (a control proves an untrimmed paragraph
   is not rebuilt).
2. **The perf gates time a paragraph, not a viewport.** Added
   `WYSIWYGViewportPerformanceGateTests`, which times the range `MarkdownEditorView`
   requests for a laid-out 1200 x 800 editor.
3. **The pointer gates run with line numbers off.** Added
   `WYSIWYGLineNumberGutterPointerGateTests`; offsetting the click by the gutter width
   makes it fail.
4. **Known blocker: a WYSIWYG click lays out the whole document.** The hit-test in
   `MarkdownSTTextView.swift` (`wysiwygZeroWidthCharacterIndex`) calls
   `ensureLayout(for: documentRange)` and enumerates every fragment. A separate session
   owns the fix; as of this audit it has no pushed branch or PR. After it lands, rerun B5,
   B6, C.2 pointer, I6, L6 and the new gutter test.
5. **Doc drift fixed:** EditorKit doc comments in `WYSIWYGInlineFoldPresentation.swift`,
   `EditorReplaceTypes.swift` and `WYSIWYGZeroWidthTextContentProjection.swift`; the
   checklist's §D intro still described the pre-June binary toggle. Two comments in
   `MarkdownSTTextView.swift` and `MarkdownSTTextView+WYSIWYGCaret.swift` still say
   "non-user-facing development hook"; they are left to the click-layout change.
6. **Left as follow-ups:** Swift names still say Experimental
   (`experimentalWYSIWYGEnabled`, `isExperimentalWYSIWYGAvailable`, the `...ExperimentalFlag...`
   test names) and the EditorKit API still says development
   (`MarkdownEditorDevelopmentPresentation`, `_developmentPresentation`,
   `_developmentImageThumbnails`). The UserDefaults key keeps its name on purpose (D.3).
