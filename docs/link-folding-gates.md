# Link Visual Folding — Sub-Gate Specification

> **Status: COMPLETE as of 2026-07-06. Link visual folding is enabled only in Experimental WYSIWYG.**
> `docs/wysiwyg-release-checklist.md` §C.5 defers link folding behind "a separate, explicitly
> approved sub-gate". This document is that sub-gate. PR C completed every gate below, recorded
> the enabling decision, and wired the link-folding presentation only to the off-by-default
> Experimental WYSIWYG mode.

Created 2026-07-02 as planning follow-up after PR #51 (Experimental WYSIWYG dogfood polish)
merged. See `agent.md` §13, `docs/wysiwyg-design.md`, and checklist §C.5/§E.

## 1. Scope

- **In scope:** inline links `[text](url)` in the WYSIWYG (inline fold/reveal) presentation.
  Folding hides the `[`, `](`, `url`, and `)` chrome; the link text stays visible with link
  styling. Reference-style links (`[text][ref]`) and autolinks (`<https://…>`) are explicitly
  **out of scope** for v1 and stay raw.
- **Out of scope (unchanged from checklist §E):** image thumbnails (`![alt](src)` stays raw),
  fenced-code fragments, tables, Mermaid/math widgets, real MDX rendering.
- The pure fold model already carries link ranges (`WYSIWYGFoldModel`; kept model-only since
  PR #38). This spec is about making them *visually* fold.

## 2. Why links are harder than the shipped constructs

Every shipped fold (heading markers, `**`, `~~`, backticks) hides a *short, symmetric*
delimiter whose interior is the visible content. A folded link hides an *asymmetric,
arbitrarily long* run (`](https://very-long-url…)`) that contains meaningful, editable text.
That changes selection, copy, caret, and reveal semantics in ways the existing gates never
exercised:

- The hidden region has real content a user may want to select/edit (the URL), not just
  syntax chrome.
- The boundary between visible text and hidden URL ("destination edge") is where carets land
  when arrowing to the end of the link text.
- Partial selections can start in visible text and end inside the hidden URL.

## 3. Gates

Mirror of the checklist §B matrix, run against the §A content-storage projection mechanism.
Each gate needs a named test (or recorded manual evidence) before it is checked.

### L1 — Fold/reveal model correctness
- [x] Folding hides exactly `[`, `](url)` (including the URL), keeps `text` visible with link
  styling, and reveal-on-touch restores the full raw source for the touched link only.
  Evidence: `WYSIWYGLinkFoldingGateTests.testL1InlineLinkFoldsExactChromeAndRevealTouchesOnlySelectedLink`
  and `...testL1ReferenceLinksAutolinksAndImagesStayRaw`.
- [x] Nested emphasis inside link text (`[**bold** link](u)`) folds/reveals without range drift.
  Evidence: `WYSIWYGLinkFoldingGateTests.testL1NestedEmphasisInsideLinkFoldsAndRevealsWithoutRangeDrift`.

### L2 — Link chrome UX policy
- [x] Folded link text renders with a link-styled attribute (color/underline per
  `EditorTheme`); no synthetic characters are inserted (no attachments, no U+FFFC).
  Evidence: `WYSIWYGLinkFoldingGateTests.testL2FoldedLinkUsesThemeStylingWithoutSyntheticCharacters`.
- [x] Pointer policy decided and recorded: plain click places the caret and reveals (Typora
  behavior, per agent.md §17.12); a modifier (⌘-click) opening the URL is optional and, if
  added, must not navigate the editor away or mutate source.
  Evidence: `agent.md` Decision Log 2026-07-06; v1 has no ⌘-click URL opening.

### L3 — Destination-edge selection & caret snapping
- [x] Arrowing right past the last visible character of link text snaps/reveals per the
  §C.2 edge-snapping policy instead of stranding the caret inside the hidden URL.
  Evidence: `WYSIWYGLinkNativeGateTests.testL3ArrowAcrossDestinationSnapsToVisibleBoundaryWithoutURLTrap`.
- [x] `WYSIWYGCaretSnap` (or a link-aware extension of it) handles the asymmetric span:
  caret rest inside any hidden `](url)` offset resolves to a visible boundary.
  Evidence: `WYSIWYGLinkNativeGateTests.testL3AsymmetricDestinationSnapUsesCompleteLongHiddenRun`
  and `...testL3ArrowAcrossDestinationSnapsToVisibleBoundaryWithoutURLTrap`.
- [x] Shift-selection across the destination edge keeps raw UTF-16 offsets (no clamping —
  checklist §C.3 stays law).
  Evidence: `WYSIWYGLinkNativeGateTests.testL3ShiftSelectionAcrossDestinationKeepsRawUTF16Offsets`.

### L4 — Copy/paste policy (B7 extension)
- [x] Selection spanning the whole link copies `[text](url)` verbatim.
  Evidence: `WYSIWYGLinkNativeGateTests.testL4WholeTextAndPartialURLSelectionsCopyExactRawRanges`.
- [x] Selection of visible text only copies the text only.
  Evidence: `WYSIWYGLinkNativeGateTests.testL4WholeTextAndPartialURLSelectionsCopyExactRawRanges`.
- [x] Selection ending *inside* the hidden URL copies exactly the selected raw `NSRange`,
  including the partial URL — never a synthesized rendered form.
  Evidence: `WYSIWYGLinkNativeGateTests.testL4WholeTextAndPartialURLSelectionsCopyExactRawRanges`
  and `...testL3ShiftSelectionAcrossDestinationKeepsRawUTF16Offsets`.
- [x] Paste into folded/revealed link regions mutates backing source normally.
  Evidence: `WYSIWYGLinkNativeGateTests.testL4PasteMutatesRawSourceInFoldedAndRevealedLinkRegions`.

### L5 — IME (Zhuyin + Pinyin) at link boundaries
- [x] Opt-in `PLAINSONG_RUN_ACTUAL_IME=1` harness extended with link-boundary scenarios:
  composition at the start/end of link text and adjacent to the folded destination; no source
  corruption, no caret escape, fold attributes skipped during marked text.
  Evidence: owner real-Mac run on 2026-07-06 passed
  `WYSIWYGActualIMEEventGateTests.testActualZhuyinEventStreamAtLinkBoundaries` and
  `...testActualPinyinEventStreamAtLinkBoundariesWhenEnabled`, including the start-of-text,
  destination-edge, and immediately-after-destination scenarios for both input methods
  (84.114 seconds total, 0 failures).

### L6 — Pointer gates
- [x] Real `NSEvent` click/drag gates (pattern of `WYSIWYGNativePointerGateTests`) rerun with
  folded links: click-to-caret on link text, boundary clicks at both edges, drag selection
  across a folded link copies exact raw Markdown.
  Evidence: `WYSIWYGLinkNativePointerGateTests.testL6RealPointerClicksOnFoldedLinkTextAndHiddenRunEdgesDoNotTrapCaret`
  and `...testL6RealPointerDragAcrossFoldedLinkCopiesExactRawMarkdown`.

### L7 — Accessibility
- [x] `AXValue` remains the exact raw source (URL included) while folded.
  Evidence: `WYSIWYGLinkNativeGateTests.testL7AccessibilityValueIncludesRawFoldedLinkDestination`.

### L8 — Performance
- [x] Visible-range fold recompute on `Fixtures/large-1mb.md` (which must gain a link-dense
  section if it lacks one) stays within the §12 50 ms budget; record in `docs/perf-log.md`.
  Evidence: `WYSIWYGLinkPerformanceGateTests.testL8LinkFoldingVisibleRangeRecomputeStaysUnderFiftyMilliseconds`
  and `docs/perf-log.md` (16.968 ms max on 2026-07-06; the existing fixture already contains
  repeated inline links and was not modified).

### L9 — Undo/redo
- [x] Link fold presentation never enters undo; editing a URL after reveal undoes as plain
  text edits.
  Evidence: `WYSIWYGLinkNativeGateTests.testL9LinkPresentationStaysOutOfUndoAndRecomputesAfterURLUndoRedo`.

## 4. Exit criteria

All L1–L9 are checked with evidence. PR C enables link folding **only behind the Experimental
WYSIWYG flag** and records the pointer/caret policy in the 2026-07-06 Decision Log entry.
Stable/default promotion of WYSIWYG as a whole remains governed by
`docs/wysiwyg-release-checklist.md` §F and is not affected by this completed sub-gate.
