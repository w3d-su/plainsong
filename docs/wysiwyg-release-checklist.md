# User-Facing WYSIWYG Release Checklist

> **Status: BLOCKING CHECKLIST. WYSIWYG is Experimental and off by default.**
> This document defines every gate that must be green before Plainsong promotes WYSIWYG beyond
> the off-by-default Experimental mode. Until every checkbox in this file is checked with linked
> evidence, WYSIWYG stays behind the Experimental Settings flag and must not become default/stable.
>
> This checklist started as a specification and now records implementation evidence as gates
> turn green. The zero-width mechanism and B1-B13 rerun gates are green as of 2026-06-26, the
> §C.2-§C.4 delimiter edge-snapping / selection / copy gates are green as of 2026-06-27,
> §D AppState/persistence/recovery/manual UI gates are green as of 2026-06-27, and the §C.5
> inline-link visual-folding sub-gate is green and included in Experimental WYSIWYG as of 2026-07-06.
> Final stable/default promotion remains blocked by the explicit unchecked promotion gate below.

Created 2026-06-26 as the deliverable for `docs/codex-handoff.md` Goal 5, after the native
interaction gates (IME §12/§13, keyboard selection/copy/paste/accessibility §12, pointer/
selection-edge §14 in `docs/wysiwyg-design.md`) passed for the attribute-only development hook.

---

## 0. How to read this checklist

- Each `- [ ]` item is a **release gate**. It blocks stable/default WYSIWYG promotion until checked.
- A gate is checked **only** with linked evidence: a test name, a PR number, or a recorded
  measurement in `docs/perf-log.md` / a design note.
- Gates are grouped: **A** (mechanism), **B** (gate-rerun matrix), **C** (UX policy),
  **D** (mode integration), **E** (scope), **F** (final sign-off).
- The order is intentional. **A blocks B**: the gate-rerun matrix (B) must run against the
  *replacement* zero-width mechanism from A, not against `baselineOffset(-1000)`. Re-running
  the matrix against the dev-hook mechanism does **not** satisfy B.

## 1. Why WYSIWYG is still blocked

What already passed (attribute-only dev hook, see `docs/wysiwyg-design.md`):

- Pure fold/reveal range model for headings, emphasis/strong, strikethrough, inline code,
  list/quote styling, and (model-only) links.
- Actual macOS **Zhuyin** and **Pinyin** IME event streams at fold boundaries.
- Native keyboard arrow movement, reverse shift-selection, copy/paste, accessibility value,
  and large-document visible-range performance.
- True pointer click-to-caret and pointer-extend (drag) selection across folded spans, with
  reveal-on-touch and exact raw-Markdown copy.

What still blocks promotion beyond Experimental:

1. **Stable/default promotion has not been approved.** WYSIWYG remains Experimental until the
   unchecked D.4 promotion gate is completed with a Decision Log entry.
2. **WYSIWYG must remain off by default.** The App may pass
   `_developmentPresentation: .inlineFoldRevealWithLinkFolding` only when the Experimental flag
   is enabled, the current layout mode is WYSIWYG, and the mechanism has not failed.
3. **Deferred constructs remain blocked.** Completing the inline-link sub-gate does not authorize
   image thumbnails, fenced-code custom fragments, tables, Mermaid/math widgets, or real MDX
   rendering in the editor surface; reference links and autolinks stay raw.

---

## A. Zero-width fold mechanism replacement (blocks everything)

### A.1 Problem

Historically, `Packages/EditorKit/Sources/EditorKit/WYSIWYGInlineFoldPresentation.swift`
folded delimiters with attribute-only hiding:

```swift
private static var foldedDelimiterFont: NSFont { .monospacedSystemFont(ofSize: 0.1, weight: .regular) }
private static var foldedDelimiterForegroundColor: NSColor { .clear }
private static var foldedDelimiterBaselineOffset: CGFloat { -1000 }
```

`baselineOffset(-1000)` does not remove the delimiter glyphs from layout; it pushes them
1000 pt off-baseline, which inflates the line fragment's height to ~1013 pt and distorts the
viewport in multi-line documents (R18). The replacement must collapse the delimiter run to
genuine zero advance **without** abusing baseline and **without** mutating source text.

The 2026-06-26 mechanism PR removes this baseline/tiny-font path from production code.

### A.2 Options evaluated

| Option | Mechanism | Pros | Cons / risks | Verdict |
|---|---|---|---|---|
| **NSTextContentStorage paragraph projection** (TextKit 2) | Install a dev-hook-only `NSTextContentStorageDelegate` that returns an `NSTextParagraph` copy only for paragraphs containing folded delimiter attributes; folded delimiter characters are projected to equal-length U+200B runs for layout. | STTextView keeps its own `NSTextLayoutManager` delegate and `STTextLayoutFragment`; delimiter advance collapses to zero; backing `NSTextStorage.string` stays exact raw Markdown; no attachments, no U+FFFC, no TextKit 1 path. | The layout paragraph differs from the backing paragraph, so raw pointer and keyboard offsets need narrow WYSIWYG-only adapters. | **CHOSEN** (2026-06-26) |
| **NSTextLayoutFragment customization** (TextKit 2) | Provide a custom `NSTextLayoutFragment` (via `NSTextLayoutManagerDelegate.textLayoutManager(_:textLayoutFragmentFor:in:)`) that lays out the delimiter elements with zero advance and skips drawing them. | Native TextKit 2 path STTextView already uses; collapses geometry correctly in principle; backing string untouched, so copy/AX value stay raw; no object-replacement characters. | STTextView 2.3.10 already owns `textLayoutManager.delegate` and returns `STTextLayoutFragment`; a direct owner would break that chain. A public `NSTextLineFragment` override prototype also did not drive TextKit's segment/`firstRect` hit-testing path reliably enough for native pointer gates. | **ATTEMPTED; not used** |
| **Attachment-based hiding** | Apply a zero-size `NSTextAttachment` (drawing nothing, `attachmentBounds` = `.zero`) over each delimiter run. | Conceptually simple; attachment cell controls its own size, so no baseline abuse. | Attachments normally pair with an object-replacement character (U+FFFC); applying one over *existing* text risks copy emitting `\u{FFFC}` and accessibility value diverging from raw source, violating the exact-raw-copy and raw-AX-value policies. Needs explicit proof those stay raw. | **FALLBACK; not needed** |
| Negative `.kern` / tiny-font only (no baseline) | Shrink + kern the run toward zero width. | No baseline inflation. | Still leaves measurable advance and selectable sub-pixel glyphs; same class of hack as the current one; fragile across fonts/zoom. | Rejected |
| TextKit 1 `NSLayoutManager` glyph generation (zero `NSGlyphProperty`) | Suppress glyphs in TextKit 1. | Well-trodden in TextKit 1 editors. | Plainsong/STTextView are TextKit 2; reintroducing a TextKit 1 layout path is a regression against the architecture. | Rejected |
| Real text deletion / replacement | Edit the backing string to drop delimiters. | Trivial layout. | Violates the non-negotiable rule that source text is the only model and is never mutated for presentation. | Rejected |

### A.3 Invariants the replacement mechanism MUST preserve

- [x] **Source canonicality.** The backing `String` is never mutated for presentation. No
  delimiter is deleted, replaced, or substituted with an object-replacement character.
  Evidence: `WYSIWYGZeroWidthTextContentProjection.swift` projects only `NSTextParagraph`
  copies; `WYSIWYGSelectionMappingSpikeTests.testProductionFoldPresentationCopyUsesRawBackingString`,
  `WYSIWYGNativeInteractionGateTests.testAccessibilityValueRemainsRawMarkdownSource`, and
  `...testPasteIntoFoldedAndRevealedRegionsMutatesBackingSourceOnly` pass.
- [x] **Geometry sanity.** A folded line's fragment height equals a normal rendered line's
  height (no ~1013 pt fragments); folding a line does not push sibling lines out of the
  viewport. Add a layout-geometry assertion (folded-line height ≈ unfolded-line height
  within tolerance) over a multi-line fixture.
  Evidence: `WYSIWYGNativePointerGateTests.testFoldedLineGeometryMatchesUnfoldedLineAndKeepsSiblingLinesInViewport`.
- [x] **Source-only mode unchanged.** With `_developmentPresentation: .source` (and in the
  shipping source-only mode), layout, selection, copy, and the line-number gutter are
  byte-for-byte unchanged from today.
  Evidence: `make test` passed on 2026-06-26; the zero-width delegate is installed only when
  `_developmentPresentation: .inlineFoldReveal` is enabled.
- [x] **Source+preview mode unchanged.** The preview pipeline, bridge, scroll sync, and
  `data-line` anchoring are unaffected by the mechanism change.
  Evidence: `make test` passed on 2026-06-26, including the Xcode `Plainsong` scheme,
  `PreviewKitTests`, and preview-src Vitest.
- [x] **Attribute compatibility.** Highlight attributes from `MarkdownSyntaxHighlighter`
  still apply over the same ranges; the new mechanism composes with highlighting rather than
  replacing it.
  Evidence: `MarkdownSyntaxHighlighterTests.testDevelopmentInlineFoldRevealFoldsIncludedConstructsAndDefersLinks`
  and `MarkdownEditorViewTests.testPartialHighlightApplyPreservesTextAndSelection`.
- [x] **No undo pollution.** Presentation continues to flow through the
  `MarkdownTextView.applyHighlightedText` path that disables undo registration and skips
  while marked text exists.
  Evidence: `MarkdownEditorViewTests.testAttributeOnlyPresentationDoesNotEnterUndoOrRedoStack`
  and `...testWYSIWYGUndoRecomputesFoldRevealStateWithoutUndoingPresentation`.

### A.4 Mechanism decision

- [x] A mechanism-prototype PR lands the TextKit 2 **NSTextContentStorage paragraph projection**
  behind the existing non-user-facing hook. The `NSTextLayoutFragment` primary was attempted
  but not used because STTextView owns the layout-fragment delegate; the attachment fallback
  was not needed. The chosen mechanism is recorded in the `agent.md` Decision Log.
- [x] `baselineOffset(-1000)` and the 0.1 pt clear-font hiding are removed from
  `WYSIWYGInlineFoldPresentation.swift` (or demoted to an explicitly test-only path) once the
  replacement lands.

---

## B. Gate-rerun matrix (against the §A replacement mechanism)

Every gate below was originally proven against the `baselineOffset(-1000)` dev hook and has now rerun
against the §A replacement. "New mechanism" means the §A.4 content-storage projection, not the old
baseline-offset mechanism.

| # | Gate | Current evidence (dev hook) | Rerun requirement | Status |
|---|---|---|---|---|
| B1 | Actual Zhuyin IME event stream | `WYSIWYGActualIMEEventGateTests/testActualZhuyinEventStreamAtFoldBoundaries` (opt-in) | Re-run opt-in harness against new mechanism; no source corruption, no caret escape, no premature commit, fold attrs skipped during marked text, reapplied after commit | - [x] 2026-06-26: `PLAINSONG_RUN_ACTUAL_IME=1 swift test --filter WYSIWYGActualIMEEventGateTests` passed; Zhuyin input source `com.apple.inputmethod.TCIM.Zhuyin` |
| B2 | Actual Pinyin IME event stream | `WYSIWYGActualIMEEventGateTests/testActualPinyinEventStreamAtFoldBoundariesWhenEnabled` (opt-in) | Re-run opt-in harness against new mechanism; same acceptance as B1 | - [x] 2026-06-26: same opt-in command passed; Pinyin input source `com.apple.inputmethod.TCIM.Pinyin` |
| B3 | Keyboard arrow movement near folded delimiters | `WYSIWYGNativeInteractionGateTests.testNativeArrowIntoFoldedDelimiterSnapsToInnerEdgeAndReveals` | Re-run; caret stays sane, touched span reveals, no trap, composed-character endpoints stay valid | - [x] `WYSIWYGNativeInteractionGateTests.testNativeArrowIntoFoldedDelimiterSnapsToInnerEdgeAndReveals` and `...testWYSIWYGMoveLeftRightSkipsEmojiComposedCharacterAndCJKBoundaries` (caret rest upgraded from reveal-only to edge-snapping 2026-06-27, §C.2) |
| B4 | Reverse shift-selection across folded spans | `...testReverseShiftSelectionAcrossFoldedStrikeKeepsRawRangeAndRevealStateSane` | Re-run; selected range is exact raw Markdown, region reveals, copy is raw, composed-character endpoints stay valid | - [x] `WYSIWYGNativeInteractionGateTests.testReverseShiftSelectionAcrossFoldedStrikeKeepsRawRangeAndRevealStateSane` and `...testWYSIWYGShiftSelectionAcrossComposedCharactersAndFoldedInlineSpansCopiesExactMarkdown` |
| B5 | True pointer click-to-caret | `WYSIWYGNativePointerGateTests.testPointerClick*` / `testPointerBoundaryClicks*` | Re-run real `NSEvent` hit-testing against new fragment geometry; sane caret, reveal-on-touch, no trap | - [x] `WYSIWYGNativePointerGateTests.testPointerClickAcrossFoldedInlineDelimitersPlacesSaneCaretAndReveals`, `...testPointerClickOnFoldedHeadingContentRevealsMarkerWithoutTrap`, `...testPointerBoundaryClicksAtFoldedDelimiterEdgesDoNotTrapCaret` |
| B6 | Pointer drag (pointer-extend) selection across folds | `WYSIWYGNativePointerGateTests.testPointerDragSelectionAcrossFoldedSpansKeepsRawRangeAndCopy` | Re-run; sane non-empty range, exact raw-Markdown copy, all touched spans reveal | - [x] `WYSIWYGNativePointerGateTests.testPointerDragSelectionAcrossFoldedSpansKeepsRawRangeAndCopy` |
| B7 | Copy = exact raw Markdown policy | `WYSIWYGNativeInteractionGateTests.testPartialFoldedSpanCopyPolicyUsesExactRawSelection` | Re-run; entire spans include delimiters, content-only copies content, boundary copies exact `NSRange` | - [x] `WYSIWYGNativeInteractionGateTests.testPartialFoldedSpanCopyPolicyUsesExactRawSelection` and `...testNativeShiftSelectionAcrossFoldedBoldStrikeAndInlineCodeCopiesRawMarkdown` |
| B8 | Paste through folded/revealed regions | `...testPasteIntoFoldedAndRevealedRegionsMutatesBackingSourceOnly` | Re-run; backing string mutates normally, no ORC/presentation-only text inserted | - [x] `WYSIWYGNativeInteractionGateTests.testPasteIntoFoldedAndRevealedRegionsMutatesBackingSourceOnly` |
| B9 | Accessibility value / role | `...testAccessibilityValueRemainsRawMarkdownSource` | Re-run; `AXTextArea` value is exact raw Markdown under the new mechanism (critical for attachment fallback) | - [x] `WYSIWYGNativeInteractionGateTests.testAccessibilityValueRemainsRawMarkdownSource` |
| B10 | Large-document visible-range performance | `MarkdownEditorViewTests.testWYSIWYGVisibleRangeFoldRecomputeStaysUnderHighlightBudget` (≤ 50 ms, §12) | Re-run on the 1 MB fixture against new mechanism; record result in `docs/perf-log.md` | - [x] `MarkdownEditorViewTests.testWYSIWYGVisibleRangeFoldRecomputeStaysUnderHighlightBudget` recorded `WYSIWYG visible-range fold highlight/apply: 26.964 ms`; see `docs/perf-log.md` |
| B11 | Undo / redo | `MarkdownEditorViewTests.testWYSIWYGUndoRecomputesFoldRevealStateWithoutUndoingPresentation` | Re-run; presentation never enters undo, stale presentation rejected, fold state recomputed | - [x] `MarkdownEditorViewTests.testAttributeOnlyPresentationDoesNotEnterUndoOrRedoStack` and `...testWYSIWYGUndoRecomputesFoldRevealStateWithoutUndoingPresentation` |
| B12 | Source-only / source+preview regression | source-only + source+preview existing EditorKit/App tests | Re-run full `make test`; confirm A.3 "unchanged" invariants hold with the mechanism present | - [x] 2026-06-26: full `make test` passed, including package tests, Xcode `Plainsong` scheme, and preview-src Vitest |
| B13 | Layout-geometry sanity (new) | none (new gate for the new mechanism) | New test: folded-line fragment height ≈ unfolded-line height; multi-line fold does not displace the viewport (closes R18) | - [x] `WYSIWYGNativePointerGateTests.testFoldedLineGeometryMatchesUnfoldedLineAndKeepsSiblingLinesInViewport` |

---

## C. UX policy

### C.1 Reveal-on-touch timing

- Reveal-on-touch (any caret/selection touching a span reveals that span's delimiters on the
  next presentation pass) is the **baseline correctness guarantee** and is retained.
- [x] Reveal recompute remains scheduled on selection change and stays within the §12
  visible-range budget; it must not introduce a perceptible delay between caret landing and
  reveal beyond one presentation pass. Evidence: the §B10 large-document visible-range probe stayed
  under budget, §C.2 edge-snapping/reveal tests remain green, and the 2026-06-27 manual WYSIWYG
  sign-off verified inline fold/reveal in the app.

### C.2 Delimiter edge-snapping

Edge-snapping is a UX refinement (avoid a one-frame reveal flicker; make arrow/click landing
feel intentional). It is **required for the user-facing mode** even though it was not needed
for the dev hook.

- [x] When the caret would land inside a still-folded delimiter offset via keyboard arrow,
  it snaps to the nearest reveal-range edge (delimiter-inner boundary) rather than relying
  solely on the next-pass reveal.
  Evidence: `MarkdownSTTextView.applyWYSIWYGComposedCharacterMovement` snaps collapsed-caret
  destinations via `WYSIWYGCaretSnap.snap`;
  `WYSIWYGEdgeSnappingGateTests.testArrowRightIntoFoldedBoldOpeningDelimiterSnapsToContentStart`,
  `...testArrowLeftIntoFoldedBoldClosingDelimiterSnapsToContentEnd`,
  `...testArrowIntoFoldedStrikeOpeningDelimiterSnapsToContentStart`,
  `...testArrowIntoFoldedStrikeClosingDelimiterSnapsToContentEnd`,
  `...testArrowRightIntoFoldedHeadingMarkerSnapsToContentStart`, and
  `...testArrowAcrossFoldedInlineCodeSingleBacktickPlacesCaretAtContentWithoutTrap` pass.
- [x] When a pointer click resolves to a hidden-delimiter offset, the caret snaps to the
  adjacent visible boundary in the same pass as the reveal (no visible one-frame jump).
  Evidence: the non-shift `MarkdownSTTextView.mouseDown` branch snaps the hit-test result
  with `.nearest`; `WYSIWYGEdgeSnappingGateTests.testPointerCaretSnapResolvesHiddenDelimiterOffsetToVisibleBoundary`
  and `...testRealPointerClicksAtFoldedDelimiterEdgesLandOnVisibleBoundary` pass.
- [x] Edge-snapping never changes the **source** selection semantics: selection/copy still
  operate on raw UTF-16 source offsets; snapping only adjusts where the caret rests, never
  what bytes a range covers.
  Evidence: snapping only runs for collapsed carets (the extending keyboard branch and the
  shift `mouseDown` branch are untouched);
  `WYSIWYGEdgeSnappingGateTests.testShiftSelectionAcrossFoldedDelimitersStillCopiesExactRawMarkdown`
  and the existing `WYSIWYGNativePointerGateTests.testPointerDragSelectionAcrossFoldedSpansKeepsRawRangeAndCopy`
  pass.

### C.3 Selection landing on delimiter offsets

- [x] Selection (not just the caret) **may** still span raw delimiter offsets — that is how
  copy stays exact raw Markdown. Edge-snapping applies to caret rest position, not to
  clamping selection ranges. This must be explicit so a future change does not "helpfully"
  clamp selections and break B7.
  Evidence: `WYSIWYGCaretSnap.snap` is only invoked for collapsed carets;
  `WYSIWYGEdgeSnappingGateTests.testShiftSelectionAcrossFoldedDelimitersStillCopiesExactRawMarkdown`
  builds a shift-selection that spans `**bold**` and copies it verbatim, and
  `...testComposedCharacterMovementStaysValidWithSnappingEnabled` confirms snapping coexists
  with composed-character movement.

### C.4 Copy policy

- [x] Copy remains **exact raw Markdown for the selected source range** (entire folded spans
  include their delimiters; content-only selections copy content only; boundary selections
  copy exactly the selected `NSRange`). The editor never synthesizes rendered/plaintext copy
  output from folded presentation. Any change to this policy requires its own Decision Log
  entry and re-runs B6/B7.
  Evidence: unchanged from §B (`WYSIWYGNativeInteractionGateTests.testPartialFoldedSpanCopyPolicyUsesExactRawSelection`,
  `WYSIWYGNativePointerGateTests.testPointerDragSelectionAcrossFoldedSpansKeepsRawRangeAndCopy`);
  edge-snapping added no copy-path changes, and
  `WYSIWYGEdgeSnappingGateTests.testShiftSelectionAcrossFoldedDelimitersStillCopiesExactRawMarkdown`
  re-confirms raw copy after snapping landed.

### C.5 Link visual folding included through its completed sub-gate

- [x] Inline links `[text](url)` visually fold only in the off-by-default Experimental WYSIWYG
  mode after the dedicated L1-L9 sub-gate completed. Link text remains visible and styled;
  plain click places the caret and reveals the raw link (Typora-style), while reference links,
  autolinks, and images stay raw. Source-only/source+preview behavior, exact-raw-copy policy,
  selection ranges, and the kill-switch fallback are unchanged. Evidence:
  `docs/link-folding-gates.md`, the owner real-Mac Zhuyin/Pinyin run on 2026-07-06, and the
  `agent.md` 2026-07-06 Decision Log entry.

---

## D. Mode integration

Today the App exposes a **binary** preview toggle: `AppState.isPreviewVisible` (⌘⇧P), persisted
under `UserDefaults` key `Plainsong.preview.isVisible` (`App/AppState.swift`). WYSIWYG turns
this into a **three-state** cycle per `agent.md` §13.

### D.1 `⌘⇧P` cycle

- [x] AppState's layout cycle goes **source+preview → source-only → WYSIWYG → source+preview**
  when WYSIWYG is enabled. Evidence:
  `AppStateTests.testLayoutModeCycleIncludesWYSIWYGWhenExperimentalFlagIsEnabled`.
- [x] When WYSIWYG is **disabled** (experimental flag off, or mechanism unhealthy per D.3),
  AppState cycles only the existing two states and never lands on WYSIWYG. No dead/disabled
  WYSIWYG stop appears in the cycle. Evidence:
  `AppStateTests.testLayoutModeCycleSkipsWYSIWYGWhenExperimentalFlagIsDisabled` and
  `AppStateTests.testWYSIWYGMechanismFailureFallsBackToSourceOnlyWithoutChangingText`.
- [x] The View menu and toolbar control reflect the current mode in manual UI validation.
  Evidence: 2026-06-27 Debug app sign-off verified:
  disabled flag cycle `sourcePreview -> sourceOnly -> sourcePreview` with menu/toolbar labels
  `Show Source Only` / `Source Only` then `Show Preview` / `Preview`; enabled flag cycle
  `sourcePreview -> sourceOnly -> wysiwyg -> sourcePreview` with labels
  `Show Source Only` / `Source Only`, `Show WYSIWYG (Experimental)` / `WYSIWYG`, and
  `Show Source + Preview` / `Source + Preview`.

### D.2 Persisted layout mode

- [x] Layout mode is persisted as a **three-state enum** (`EditorLayoutMode`:
  `.sourcePreview` / `.sourceOnly` / `.wysiwyg`), replacing the bare boolean. Evidence:
  `AppStateTests.testPreviewVisibilityPersistsThroughUserDefaults` and the enabled/disabled
  cycle tests.
- [x] A **migration** maps the legacy `Plainsong.preview.isVisible` boolean to the new enum on
  first launch (`true → .sourcePreview`, `false → .sourceOnly`) so existing users keep their
  layout. Evidence: `AppStateTests.testLayoutModeMigratesLegacyVisiblePreviewPreference` and
  `AppStateTests.testLayoutModeMigratesLegacyHiddenPreviewPreference`.
- [x] `.wysiwyg` is only **persisted** when the feature is enabled; if it is read back while
  the feature is disabled, it resolves per D.3 recovery instead of forcing WYSIWYG on. Evidence:
  `AppStateTests.testPersistedWYSIWYGFallsBackToSourceOnlyWhenExperimentalFlagIsDisabled`.

### D.3 Failure / disable recovery

- [x] An explicit **kill switch** exists (the off-by-default
  `Plainsong.settings.experimentalWYSIWYGEnabled` `UserDefaults` flag) that disables WYSIWYG
  entirely without removing source-only/source+preview. Evidence:
  `AppStateTests.testLayoutModeCycleSkipsWYSIWYGWhenExperimentalFlagIsDisabled`.
- [x] If the WYSIWYG mechanism fails to initialize or is disabled at launch, a persisted
  `.wysiwyg` mode **falls back deterministically** to `.sourceOnly` (safest: pure text, no
  preview dependency) and the user is not left in a broken pane. Evidence:
  `AppStateTests.testPersistedWYSIWYGFallsBackToSourceOnlyWhenExperimentalFlagIsDisabled`.
- [x] A mechanism failure mid-session degrades to `.sourceOnly` without data loss (source text
  is canonical and untouched), and the failure is logged/exposed through AppState recovery state,
  not silently swallowed. Evidence:
  `AppStateTests.testWYSIWYGMechanismFailureFallsBackToSourceOnlyWithoutChangingText`.

### D.4 Experimental vs stable labeling

- [x] Until **every** gate in this document is green, WYSIWYG ships (if at all) behind an
  **Experimental** Settings toggle and is **off by default**. Evidence:
  `AppStateTests.testSettingsPreferencesPersistThroughUserDefaults` verifies the preference default
  and persistence.
- [x] The Experimental label is manually verified in Settings UI and user-facing docs/README.
  Evidence: 2026-06-27 Settings UI sign-off verified `WYSIWYG mode (Experimental)` with value `0`
  by default, and README states WYSIWYG is Experimental/off by default.
- [ ] Promotion from experimental to stable (on by default / no experimental label) requires
  this checklist fully green and a Decision Log entry recording the promotion.

---

## E. Construct scope (unchanged; do not expand here)

User-facing WYSIWYG v1 stays inline-first. Included: **headings, emphasis/strong,
strikethrough, inline code, list/quote marker styling, and inline links `[text](url)`**.
Inline-link folding completed its own L1-L9 gate (see C.5); reference-style links and autolinks
stay raw. The following remain **deferred** and must not be added as part of this scope:

- [x] Inline link visual folding — included only in Experimental WYSIWYG after the completed C.5 sub-gate.
- [x] Reference-style links and autolinks — stay raw.
- [x] Image thumbnails — deferred.
- [x] Fenced-code custom layout fragments — deferred.
- [x] Tables — stay raw; existing table helper remains.
- [x] Mermaid / math widgets — stay raw in editor; preview pane renders.
- [x] Real MDX component rendering — stays placeholder/source.

Each deferred construct, when eventually built, needs its own gate pass (IME/selection/pointer/
copy/accessibility/performance) against the §A mechanism before it becomes user-facing.

---

## F. Final release sign-off

WYSIWYG may be promoted beyond off-by-default Experimental only when **all** of the following are
checked:

- [x] **A** — Replacement zero-width mechanism landed; A.3 invariants proven; `baselineOffset(-1000)`
  removed/demoted; mechanism recorded in Decision Log.
- [x] **B** — Every row B1–B13 re-run and green against the §A mechanism; performance recorded in
  `docs/perf-log.md`.
- [x] **C** — Reveal-on-touch, edge-snapping, selection/copy, and inline-link policies implemented
  and tested. Edge-snapping and selection/copy gates are covered by `WYSIWYGEdgeSnappingGateTests`
  and native interaction tests; the completed link sub-gate and 2026-07-06 owner actual-IME run
  cover inline-link folding in Experimental WYSIWYG.
- [x] **D** — Three-state `⌘⇧P` cycle, persisted enum + migration, kill switch + recovery, and
  experimental labeling implemented and tested. Automated AppState tests cover persistence/recovery;
  2026-06-27 manual sign-off covers Settings label/default, View menu, toolbar, enabled/disabled
  cycles, and disable-from-WYSIWYG fallback.
- [x] **E** — Inline links are included through their completed sub-gate; all remaining deferred
  constructs stay deferred and reference links/autolinks remain raw.
- [x] **Docs** — `docs/wysiwyg-design.md`, `docs/risk-register.md` (R18 closed only when B13 +
  A complete), `docs/codex-handoff.md`, README/Settings copy, and `agent.md` Decision Log all
  synchronized with the shipped behavior.

Until the stable-promotion gate is checked, the only valid WYSIWYG surfaces are the off-by-default
Experimental mode (using `.inlineFoldRevealWithLinkFolding`) and non-user-facing development hooks.

---

## References

- `docs/wysiwyg-design.md` §10–§14 — spike results, production core, and native interaction gates.
- `docs/risk-register.md` — R10 (selection/caret), R11 (copy policy), R12 (checklist-before-gates),
  R18 (zero-width mechanism distortion).
- `docs/codex-handoff.md` — Goals 4-8 and remaining release sign-off notes.
- `Packages/EditorKit/Sources/EditorKit/WYSIWYGZeroWidthTextContentProjection.swift` — current
  zero-width mechanism.
- `Packages/EditorKit/Tests/EditorKitTests/WYSIWYGNativePointerGateTests.swift`,
  `WYSIWYGNativeInteractionGateTests.swift`, `WYSIWYGActualIMEEventGateTests.swift`,
  `WYSIWYGIMESpikeTests.swift`, `WYSIWYGSelectionMappingSpikeTests.swift` — gate evidence.
- `App/AppState.swift` — three-state layout mode, migration, Experimental gate, and fallback behavior.
- `agent.md` §13, §17, Decision Log — Phase 2 scope, layering, and decision history.
