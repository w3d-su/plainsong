# User-Facing WYSIWYG Release Checklist

> **Status: BLOCKING SPECIFICATION. WYSIWYG is not user-facing.**
> This document defines every gate that must be green before Plainsong exposes a WYSIWYG
> editing mode to users. Until every checkbox in this file is checked with linked evidence,
> WYSIWYG stays behind `MarkdownEditorView(..., _developmentPresentation: .inlineFoldReveal)`,
> out of the `⌘⇧P` cycle, and out of persisted layout state.
>
> This is a **specification PR**. It adds no user-facing mode, no persisted WYSIWYG layout
> value, no link visual folding, and no new construct rendering. It tells the next
> implementation PRs exactly what to build and what to re-prove.

Created 2026-06-26 as the deliverable for `docs/codex-handoff.md` Goal 5, after the native
interaction gates (IME §12/§13, keyboard selection/copy/paste/accessibility §12, pointer/
selection-edge §14 in `docs/wysiwyg-design.md`) passed for the attribute-only development hook.

---

## 0. How to read this checklist

- Each `- [ ]` item is a **release gate**. It blocks user-facing WYSIWYG until checked.
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

What still blocks a user-facing mode:

1. **Mechanism (R18).** The dev hook hides delimiters with `baselineOffset(-1000)` + a
   0.1 pt clear font. A single folded line lays out as an ~1013 pt-tall fragment. It does not
   trap the caret, but in multi-line documents the geometry pushes sibling lines outside the
   viewport. This is acceptable for tests, **not** for a mode users edit in.
2. **All native gates were proven against that throwaway mechanism.** A cleaner mechanism is
   a different layout path, so IME/selection/pointer/accessibility/performance must rerun
   against it (§A constraints in `docs/wysiwyg-design.md` §10/§11).
3. **No UX policy** for delimiter edge-snapping, mode cycling, persistence, or experimental
   labeling has been specified or implemented.

---

## A. Zero-width fold mechanism replacement (blocks everything)

### A.1 Problem

`Packages/EditorKit/Sources/EditorKit/WYSIWYGInlineFoldPresentation.swift` folds delimiters
with attribute-only hiding:

```swift
private static var foldedDelimiterFont: NSFont { .monospacedSystemFont(ofSize: 0.1, weight: .regular) }
private static var foldedDelimiterForegroundColor: NSColor { .clear }
private static var foldedDelimiterBaselineOffset: CGFloat { -1000 }
```

`baselineOffset(-1000)` does not remove the delimiter glyphs from layout; it pushes them
1000 pt off-baseline, which inflates the line fragment's height to ~1013 pt and distorts the
viewport in multi-line documents (R18). The replacement must collapse the delimiter run to
genuine zero advance **without** abusing baseline and **without** mutating source text.

### A.2 Options evaluated

| Option | Mechanism | Pros | Cons / risks | Verdict |
|---|---|---|---|---|
| **NSTextLayoutFragment customization** (TextKit 2) | Provide a custom `NSTextLayoutFragment` (via `NSTextLayoutManagerDelegate.textLayoutManager(_:textLayoutFragmentFor:in:)`) that lays out the delimiter elements with zero advance and skips drawing them. | Native TextKit 2 path STTextView already uses; collapses geometry correctly (no 1013 pt line); backing string untouched, so copy/AX value stay raw; no object-replacement characters. | Must confirm STTextView lets us own / chain the layout-fragment delegate without breaking its own fragment work; fragment math is the trickiest TextKit 2 surface; caret/firstRect mapping into a collapsed run must be re-verified. | **PRIMARY** |
| **Attachment-based hiding** | Apply a zero-size `NSTextAttachment` (drawing nothing, `attachmentBounds` = `.zero`) over each delimiter run. | Conceptually simple; attachment cell controls its own size, so no baseline abuse. | Attachments normally pair with an object-replacement character (U+FFFC); applying one over *existing* text risks copy emitting `\u{FFFC}` and accessibility value diverging from raw source, violating the exact-raw-copy and raw-AX-value policies. Needs explicit proof those stay raw. | **FALLBACK** (only if A.3 invariants pass with extra copy/AX coverage) |
| Negative `.kern` / tiny-font only (no baseline) | Shrink + kern the run toward zero width. | No baseline inflation. | Still leaves measurable advance and selectable sub-pixel glyphs; same class of hack as the current one; fragile across fonts/zoom. | Rejected |
| TextKit 1 `NSLayoutManager` glyph generation (zero `NSGlyphProperty`) | Suppress glyphs in TextKit 1. | Well-trodden in TextKit 1 editors. | Plainsong/STTextView are TextKit 2; reintroducing a TextKit 1 layout path is a regression against the architecture. | Rejected |
| Real text deletion / replacement | Edit the backing string to drop delimiters. | Trivial layout. | Violates the non-negotiable rule that source text is the only model and is never mutated for presentation. | Rejected |

### A.3 Invariants the replacement mechanism MUST preserve

- [ ] **Source canonicality.** The backing `String` is never mutated for presentation. No
  delimiter is deleted, replaced, or substituted with an object-replacement character.
- [ ] **Geometry sanity.** A folded line's fragment height equals a normal rendered line's
  height (no ~1013 pt fragments); folding a line does not push sibling lines out of the
  viewport. Add a layout-geometry assertion (folded-line height ≈ unfolded-line height
  within tolerance) over a multi-line fixture.
- [ ] **Source-only mode unchanged.** With `_developmentPresentation: .source` (and in the
  shipping source-only mode), layout, selection, copy, and the line-number gutter are
  byte-for-byte unchanged from today.
- [ ] **Source+preview mode unchanged.** The preview pipeline, bridge, scroll sync, and
  `data-line` anchoring are unaffected by the mechanism change.
- [ ] **Attribute compatibility.** Highlight attributes from `MarkdownSyntaxHighlighter`
  still apply over the same ranges; the new mechanism composes with highlighting rather than
  replacing it.
- [ ] **No undo pollution.** Presentation continues to flow through the
  `MarkdownTextView.applyHighlightedText` path that disables undo registration and skips
  while marked text exists.

### A.4 Mechanism decision

- [ ] A mechanism-prototype PR lands the **NSTextLayoutFragment customization** path (primary)
  behind the existing non-user-facing hook, or — if STTextView cannot host the custom
  fragment cleanly — the **attachment-based** fallback with the extra copy/accessibility proof
  required by A.2. The chosen mechanism is recorded in the `agent.md` Decision Log.
- [ ] `baselineOffset(-1000)` and the 0.1 pt clear-font hiding are removed from
  `WYSIWYGInlineFoldPresentation.swift` (or demoted to an explicitly test-only path) once the
  replacement lands.

---

## B. Gate-rerun matrix (against the §A replacement mechanism)

Every gate below was proven against the `baselineOffset(-1000)` dev hook. Each must rerun and
pass against the §A replacement before WYSIWYG is user-facing. "New mechanism" means the §A.4
mechanism, not the current one.

| # | Gate | Current evidence (dev hook) | Rerun requirement | Status |
|---|---|---|---|---|
| B1 | Actual Zhuyin IME event stream | `WYSIWYGActualIMEEventGateTests/testActualZhuyinEventStreamAtFoldBoundaries` (opt-in) | Re-run opt-in harness against new mechanism; no source corruption, no caret escape, no premature commit, fold attrs skipped during marked text, reapplied after commit | - [ ] |
| B2 | Actual Pinyin IME event stream | `WYSIWYGActualIMEEventGateTests/testActualPinyinEventStreamAtFoldBoundariesWhenEnabled` (opt-in) | Re-run opt-in harness against new mechanism; same acceptance as B1 | - [ ] |
| B3 | Keyboard arrow movement near folded delimiters | `WYSIWYGNativeInteractionGateTests.testNativeArrowLandingInsideFoldedDelimiterRevealsInsteadOfTrapping` | Re-run; caret stays sane, touched span reveals, no trap | - [ ] |
| B4 | Reverse shift-selection across folded spans | `...testReverseShiftSelectionAcrossFoldedStrikeKeepsRawRangeAndRevealStateSane` | Re-run; selected range is exact raw Markdown, region reveals, copy is raw | - [ ] |
| B5 | True pointer click-to-caret | `WYSIWYGNativePointerGateTests.testPointerClick*` / `testPointerBoundaryClicks*` | Re-run real `NSEvent` hit-testing against new fragment geometry; sane caret, reveal-on-touch, no trap | - [ ] |
| B6 | Pointer drag (pointer-extend) selection across folds | `WYSIWYGNativePointerGateTests.testPointerDragSelectionAcrossFoldedSpansKeepsRawRangeAndCopy` | Re-run; sane non-empty range, exact raw-Markdown copy, all touched spans reveal | - [ ] |
| B7 | Copy = exact raw Markdown policy | `WYSIWYGNativeInteractionGateTests.testPartialFoldedSpanCopyPolicyUsesExactRawSelection` | Re-run; entire spans include delimiters, content-only copies content, boundary copies exact `NSRange` | - [ ] |
| B8 | Paste through folded/revealed regions | `...testPasteIntoFoldedAndRevealedRegionsMutatesBackingSourceOnly` | Re-run; backing string mutates normally, no ORC/presentation-only text inserted | - [ ] |
| B9 | Accessibility value / role | `...testAccessibilityValueRemainsRawMarkdownSource` | Re-run; `AXTextArea` value is exact raw Markdown under the new mechanism (critical for attachment fallback) | - [ ] |
| B10 | Large-document visible-range performance | `MarkdownEditorViewTests.testWYSIWYGVisibleRangeFoldRecomputeStaysUnderHighlightBudget` (≤ 50 ms, §12) | Re-run on the 1 MB fixture against new mechanism; record result in `docs/perf-log.md` | - [ ] |
| B11 | Undo / redo | `MarkdownEditorViewTests.testWYSIWYGUndoRecomputesFoldRevealStateWithoutUndoingPresentation` | Re-run; presentation never enters undo, stale presentation rejected, fold state recomputed | - [ ] |
| B12 | Source-only / source+preview regression | source-only + source+preview existing EditorKit/App tests | Re-run full `make test`; confirm A.3 "unchanged" invariants hold with the mechanism present | - [ ] |
| B13 | Layout-geometry sanity (new) | none (new gate for the new mechanism) | New test: folded-line fragment height ≈ unfolded-line height; multi-line fold does not displace the viewport (closes R18) | - [ ] |

---

## C. UX policy

### C.1 Reveal-on-touch timing

- Reveal-on-touch (any caret/selection touching a span reveals that span's delimiters on the
  next presentation pass) is the **baseline correctness guarantee** and is retained.
- [ ] Reveal recompute remains scheduled on selection change and stays within the §12
  visible-range budget; it must not introduce a perceptible delay between caret landing and
  reveal beyond one presentation pass.

### C.2 Delimiter edge-snapping

Edge-snapping is a UX refinement (avoid a one-frame reveal flicker; make arrow/click landing
feel intentional). It is **required for the user-facing mode** even though it was not needed
for the dev hook.

- [ ] When the caret would land inside a still-folded delimiter offset via keyboard arrow,
  it snaps to the nearest reveal-range edge (delimiter-inner boundary) rather than relying
  solely on the next-pass reveal.
- [ ] When a pointer click resolves to a hidden-delimiter offset, the caret snaps to the
  adjacent visible boundary in the same pass as the reveal (no visible one-frame jump).
- [ ] Edge-snapping never changes the **source** selection semantics: selection/copy still
  operate on raw UTF-16 source offsets; snapping only adjusts where the caret rests, never
  what bytes a range covers.

### C.3 Selection landing on delimiter offsets

- [ ] Selection (not just the caret) **may** still span raw delimiter offsets — that is how
  copy stays exact raw Markdown. Edge-snapping applies to caret rest position, not to
  clamping selection ranges. This must be explicit so a future change does not "helpfully"
  clamp selections and break B7.

### C.4 Copy policy

- [ ] Copy remains **exact raw Markdown for the selected source range** (entire folded spans
  include their delimiters; content-only selections copy content only; boundary selections
  copy exactly the selected `NSRange`). The editor never synthesizes rendered/plaintext copy
  output from folded presentation. Any change to this policy requires its own Decision Log
  entry and re-runs B6/B7.

### C.5 Link visual folding stays deferred

- [ ] Link visual folding remains **off** in the user-facing v1. Link ranges stay in the pure
  fold model for offset/reveal validation, but `[text](url)` is not visually folded until link
  chrome, destination-edge selection, and partial-span copy have their own native
  selection/copy/pointer gates (a separate, explicitly approved sub-gate). Shipping the
  user-facing mode does **not** unblock link folding.

---

## D. Mode integration

Today the App exposes a **binary** preview toggle: `AppState.isPreviewVisible` (⌘⇧P), persisted
under `UserDefaults` key `Plainsong.preview.isVisible` (`App/AppState.swift`). WYSIWYG turns
this into a **three-state** cycle per `agent.md` §13.

### D.1 `⌘⇧P` cycle

- [ ] `⌘⇧P` cycles **source+preview → source-only → WYSIWYG → source+preview** when WYSIWYG is
  enabled. The View menu and toolbar control reflect the current mode.
- [ ] When WYSIWYG is **disabled** (experimental flag off, or mechanism unhealthy per D.3),
  `⌘⇧P` cycles only the existing two states and never lands on WYSIWYG. No dead/disabled
  WYSIWYG stop appears in the cycle.

### D.2 Persisted layout mode

- [ ] Layout mode is persisted as a **three-state enum** (e.g. `PreviewLayoutMode`:
  `.sourcePreview` / `.sourceOnly` / `.wysiwyg`), replacing the bare boolean.
- [ ] A **migration** maps the legacy `Plainsong.preview.isVisible` boolean to the new enum on
  first launch (`true → .sourcePreview`, `false → .sourceOnly`) so existing users keep their
  layout. Document the one-time reset behavior in the Decision Log if any preference resets.
- [ ] `.wysiwyg` is only **persisted** when the feature is enabled; if it is read back while
  the feature is disabled, it resolves per D.3 recovery instead of forcing WYSIWYG on.

### D.3 Failure / disable recovery

- [ ] An explicit **kill switch** exists (build flag and/or `UserDefaults` flag) that disables
  WYSIWYG entirely without removing source-only/source+preview.
- [ ] If the WYSIWYG mechanism fails to initialize or is disabled at launch, a persisted
  `.wysiwyg` mode **falls back deterministically** to `.sourceOnly` (safest: pure text, no
  preview dependency) and the user is not left in a broken pane.
- [ ] A mechanism failure mid-session degrades to `.sourceOnly` without data loss (source text
  is canonical and untouched), and the failure is logged, not silently swallowed.

### D.4 Experimental vs stable labeling

- [ ] Until **every** gate in this document is green, WYSIWYG ships (if at all) behind an
  **Experimental** Settings toggle, labeled experimental in the Settings UI and in user-facing
  docs/README. It is **off by default**.
- [ ] Promotion from experimental to stable (on by default / no experimental label) requires
  this checklist fully green and a Decision Log entry recording the promotion.

---

## E. Construct scope (unchanged; do not expand here)

User-facing WYSIWYG v1 stays inline-first. Included: **headings, emphasis/strong,
strikethrough, inline code, list/quote marker styling**. The following remain **deferred** and
must not be added as part of making WYSIWYG user-facing:

- [ ] Link visual folding stays deferred (see C.5).
- [ ] Image thumbnails — deferred.
- [ ] Fenced-code custom layout fragments — deferred.
- [ ] Tables — stay raw; existing table helper remains.
- [ ] Mermaid / math widgets — stay raw in editor; preview pane renders.
- [ ] Real MDX component rendering — stays placeholder/source.

Each deferred construct, when eventually built, needs its own gate pass (IME/selection/pointer/
copy/accessibility/performance) against the §A mechanism before it becomes user-facing.

---

## F. Final release sign-off

WYSIWYG may be exposed to users only when **all** of the following are checked:

- [ ] **A** — Replacement zero-width mechanism landed; A.3 invariants proven; `baselineOffset(-1000)`
  removed/demoted; mechanism recorded in Decision Log.
- [ ] **B** — Every row B1–B13 re-run and green against the §A mechanism; performance recorded in
  `docs/perf-log.md`.
- [ ] **C** — Reveal-on-touch, edge-snapping, selection/copy, and link-deferral policies implemented
  and tested.
- [ ] **D** — Three-state `⌘⇧P` cycle, persisted enum + migration, kill switch + recovery, and
  experimental labeling implemented and tested.
- [ ] **E** — Construct scope unchanged; deferred constructs still deferred.
- [ ] **Docs** — `docs/wysiwyg-design.md`, `docs/risk-register.md` (R18 closed only when B13 +
  A complete), `docs/codex-handoff.md`, README/Settings copy, and `agent.md` Decision Log all
  synchronized with the shipped behavior.

Until then, the only valid WYSIWYG surface is the non-user-facing
`_developmentPresentation: .inlineFoldReveal` hook.

---

## References

- `docs/wysiwyg-design.md` §10–§14 — spike results, production core, and native interaction gates.
- `docs/risk-register.md` — R10 (selection/caret), R11 (copy policy), R12 (checklist-before-gates),
  R18 (zero-width mechanism distortion).
- `docs/codex-handoff.md` — Goal 4 (pointer gate) and Goal 5 (this checklist).
- `Packages/EditorKit/Sources/EditorKit/WYSIWYGInlineFoldPresentation.swift` — current dev-hook mechanism.
- `Packages/EditorKit/Tests/EditorKitTests/WYSIWYGNativePointerGateTests.swift`,
  `WYSIWYGNativeInteractionGateTests.swift`, `WYSIWYGActualIMEEventGateTests.swift`,
  `WYSIWYGIMESpikeTests.swift`, `WYSIWYGSelectionMappingSpikeTests.swift` — gate evidence.
- `App/AppState.swift` — current binary preview toggle to be replaced by the three-state mode.
- `agent.md` §13, §17, Decision Log — Phase 2 scope, layering, and decision history.
