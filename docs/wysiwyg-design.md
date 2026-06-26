# Phase 2 — WYSIWYG Design Gate

> **Status: APPROVED FOR PHASE 2 SPIKES.** M1–M5 are accepted, so Phase 2 may begin as
> design validation and risk-reduction spikes. This approval does **not** authorize a full
> WYSIWYG implementation PR. Production implementation starts only after the approved spikes
> pass and their results are recorded here or in follow-up design notes.
>
> Scope discipline: Phase 2 stays native TextKit 2. Source text remains the only model.
> The two-pane source+preview mode remains available indefinitely.

## 1. Goal & non-goals

**Goal:** in-place WYSIWYG editing in the spirit of Typora — the rendered document is the
editing surface; raw Markdown delimiters are revealed only for the node or block the cursor
is actively editing.

**Non-goals for Phase 2 v1:**

- No `contentEditable` or web-based editor. The editing surface stays native TextKit 2.
- Do not replace source-only or source+preview mode. WYSIWYG is additive.
- Do not execute real MDX components. MDX components remain placeholders until a separate
  Phase 3+ sandbox/project-bundling design exists.
- Do not build table, Mermaid, or math WYSIWYG widgets in v1. Those stay raw and use the
  existing preview pane for rendered output.
- Do not introduce user-authored CSS/theme imports as part of WYSIWYG.

## 2. Core architectural approach

- **No text mutation for rendering.** The source `String` remains the single model, just as in
  Phase 1. WYSIWYG presentation is derived from parser ranges and attributes/layout.
- **Visible-range first.** Folding/reveal recompute runs only for visible or dirty ranges and must
  stay within the §12 typing/highlight budgets.
- **Selection-driven reveal.** The rendered state is recalculated from the current selection/caret:
  - selection outside a foldable node → hide/dim syntax delimiters and apply rendered styling;
  - selection inside a node's source range → reveal the raw Markdown for that node/block only.
- **IME-safe by default.** While marked text exists, folding/reveal updates that could affect the
  composition range are skipped or deferred. Traditional Chinese Zhuyin and Pinyin checks are gate
  conditions, not polish.
- **Undo remains text-only.** Folding attributes and layout fragments must not enter the undo stack.
- **Preview remains the heavy renderer.** Math, Mermaid, complex MDX placeholders, and other block
  renderers stay in preview until the native WYSIWYG core proves stable.

## 3. Approved Phase 2 v1 scope

| Construct | v1 decision | Rendered/folded form | Reveal trigger | Risk |
|---|---|---|---|---|
| Headings | Include | Hide `#` marker, scale/weight heading text | caret on heading line | low |
| Bold / italic / strike | Include | Hide delimiters, apply font traits | caret inside formatted span | medium |
| Inline code | Include | Hide backticks, apply code font/pill background | caret inside code span | low |
| Lists / quotes | Include | Preserve source markers but style indentation/marker subtly; no marker deletion in v1 | caret on line | low–medium |
| Links | Include after selection spike passes | Show link text with underline/dim URL affordance; hide `[]()` outside range | caret anywhere in full `[text](url)` source range | medium |
| Images | Defer from v1 core | Keep raw Markdown image syntax in first release | n/a | medium |
| Fenced code | Defer from v1 core | Keep raw fence plus existing syntax highlighting | n/a | high |
| Tables | Defer | Stay raw; existing table helper remains | n/a | very high |
| Mermaid / math | Defer | Stay raw in editor; preview pane renders | n/a | very high |
| MDX components | Defer real rendering | Keep current placeholder/source presentation | n/a | high |

The minimum shippable WYSIWYG v1 is therefore: headings, emphasis/strike, inline code,
lists/quotes, and links if Spike C proves selection mapping is safe. Images/fences can be added
later, but they must not block the inline-first WYSIWYG core.

## 4. Resolved open questions

1. **Link boundary semantics:** the full link source range `[text](url)` is the editable node.
   When the caret or selection touches any part of that range, reveal the raw Markdown for the
   whole link. Outside that range, show rendered link text.
2. **Tables/Mermaid/math:** stay raw in WYSIWYG v1. The preview pane remains the rendered view.
3. **Image thumbnails:** deferred until after the inline core and link behavior are stable. A later
   image PR must define max dimensions, async loading, cache behavior, and click/selection mapping.
4. **KaTeX/Mermaid reuse:** do not reuse preview WebView output inside TextKit for v1. Native or
   embedded rendering requires a separate design.
5. **Minimum v1 scope:** inline-first only: headings, emphasis/strike, inline code, lists/quotes,
   and links after selection tests pass.

## 5. Mandatory spike plan

Run these spikes before production WYSIWYG work. Each spike should be a small PR or draft PR with
clear results. Throwaway prototypes are allowed, but their findings must be recorded.

### Spike A — IME composition

**Risk:** marked text interacting with folded/revealed syntax can corrupt composition, move the
caret, or commit text prematurely.

**Prototype:** fold/reveal heading + bold + inline code ranges, then drive Traditional Chinese
Zhuyin and Pinyin marked text at fold boundaries and inside revealed spans.

**Accept:** marked text round-trips correctly; no caret jump; no premature commit; no delimiter
attributes are applied over the active marked range.

**Blocker rule:** if this cannot be made correct, Phase 2 implementation is blocked or WYSIWYG must
stay disabled behind an experimental flag.

### Spike B — Undo coordination

**Risk:** presentation folding can pollute undo or leave stale folded ranges after undo/redo.

**Prototype:** type, fold, reveal, edit inside a node, undo/redo repeatedly, and assert text,
selection, and presentation state recompute deterministically.

**Accept:** undo/redo changes only source text and selection. Folding state is recomputed, not stored
as undoable user content.

### Spike C — Selection and copy across folded tokens

**Risk:** arrow keys, shift-selection, mouse selection, and copy can map to wrong source offsets when
syntax delimiters are hidden.

**Prototype:** fold a bold span and a link; move by arrow key; shift-select across folded ranges;
copy; click to place the caret.

**Accept:** selection maps cleanly to source offsets, copy yields raw Markdown, no caret traps, and
link reveal semantics match §4.

## 6. Implementation sequence after spikes pass

1. **Fold/reveal range model:** pure range computation from parser tree + selection.
2. **Attribute-only inline folding:** headings, emphasis/strike, inline code, lists/quotes.
3. **Link folding:** only after Spike C passes.
4. **Mode integration:** source+preview → source-only → WYSIWYG cycle behind `⌘⇧P`, persisted across relaunch.
5. **Polish/extension PRs:** images, fenced code fragments, tables, Mermaid/math, MDX placeholder folding.

Every step must keep source-only and source+preview behavior unchanged.

## 7. Testing requirements

- IME regression tests for Zhuyin and Pinyin marked text at fold/reveal transitions.
- Unit tests for pure fold/reveal boundary logic.
- Programmatic EditorKit tests for selection, undo, copy, and typing through folded spans.
- Performance tests proving visible-range fold recompute stays within §12 budgets.
- Manual checklist for source-only/source+preview/WYSIWYG mode switching.

## 8. Phase 2 design-gate acceptance

This document resolves the Phase 2 design open questions and records the Spike A/B/C/D results. The
next valid work item is a narrow production PR for an inline-first fold/reveal engine behind
non-user-facing development plumbing. Full user-facing WYSIWYG mode remains blocked until the
production mechanism reruns these gates and passes.

## 9. Codex-ready next goal

```text
Goal: Phase 2 Spike A/B/C — prove WYSIWYG fold/reveal safety before production implementation.

Read first:
- agent.md §13 and §17
- docs/wysiwyg-design.md
- Packages/EditorKit/Sources/EditorKit/MarkdownEditorView.swift
- Packages/EditorKit/Sources/EditorKit/MarkdownTextView.swift
- Packages/EditorKit/Sources/EditorKit/MarkdownTextViewCoordinator.swift
- Packages/EditorKit/Sources/EditorKit/MarkdownSyntaxParser.swift
- Packages/EditorKit/Tests/EditorKitTests

Constraints:
- Do not ship production WYSIWYG UI in this PR.
- Do not mutate source text for presentation.
- Do not affect source-only or source+preview modes.
- Keep folding visible-range first.
- IME marked text correctness is non-negotiable.

Deliverables:
- A prototype fold/reveal range model for heading + emphasis + inline code.
- Spike A results for Zhuyin/Pinyin marked text.
- Spike B results for undo/redo.
- Spike C results for selection/copy across folded bold/link ranges.
- Tests or clearly documented manual evidence.
- A go/no-go recommendation for production Phase 2 v1 implementation.
```

## 10. Spike A/B/C/D result — 2026-06-26

**Recommendation: GO for the next production PR, limited to an inline-first fold/reveal engine.** The
spike validates the core safety premise for headings, emphasis/strike, inline code, and inline links:
source text remains canonical, fold/reveal is representable as pure source ranges, and attribute-only
presentation can be recomputed without entering undo or corrupting automated marked-text or
selection/copy state.

This is **not approval to ship production WYSIWYG UI** and does not add WYSIWYG to the user-facing
`⌘⇧P` cycle. The next PR should wire the real mechanism behind non-user-facing development plumbing
and rerun these gates before any user-visible mode change.

### Evidence

- **Prototype range model — PASS.** `WYSIWYGFoldParser` / `WYSIWYGFoldPlan` model visible-range
  fold/reveal candidates for headings, strong/emphasis/strike, inline code, and inline links without
  mutating source text or wiring editor UI. Unit coverage includes reveal boundary decisions for every
  inline folded kind, ATX and setext headings, adjacent spans, nested spans, visible-line scoping, and
  CJK UTF-16 source offsets. Dirty-range support is compatible with the stateless source-range model but
  remains a production API/performance requirement, not a separate spike API here.
- **Spike A — CONDITIONAL PASS for attribute-only folding.** `WYSIWYGIMESpikeTests` drives Zhuyin
  (`ㄊ` → `ㄊㄞ` → `ㄊㄞˊ` → `臺`) and Pinyin (`t` → `ta` → `tai` → `臺`) marked text at folded heading
  plus bold, italic, and inline-code delimiter boundaries. Marked range, source text, and caret remain
  stable; fold attributes are skipped during composition, never cover active marked text, and are reapplied
  only after commit. This is automated `setMarkedText` evidence, not actual macOS input-method event
  stream evidence.
- **Spike B — CONDITIONAL PASS for attribute-only presentation.** `MarkdownEditorViewTests` verifies
  presentation attributes do not enter undo/redo, stale presentation is rejected after undo, and a
  type → fold → reveal → edit-inside-revealed-node → undo/redo loop repeatedly restores source text,
  selection, and recomputed fold state. Redo selection currently follows STTextView native behavior by
  selecting the reinserted character; confirm that UX in the production PR.
- **Spike C/D — CONDITIONAL PASS for raw-range mapping and copy.** `WYSIWYGSelectionMappingSpikeTests`
  proves folded bold/link selections normalize to raw Markdown ranges, visible caret offsets skip hidden
  delimiter interiors in the pure projection, STTextView copy uses the raw backing string when delimiters
  are only visually hidden by attributes, and the prototype link reveal range is the full `[text](url)`
  source span. This is pure mapping plus programmatic copy evidence, not real mouse/arrow-key event
  evidence. Reverse shift-selection, native mouse placement, and partial folded-span copy policy remain
  production-gate checks.

### Production v1 constraints

- Production should reuse the existing parser/visible-range pipeline instead of owning a new parser per
  fold model instance.
- Dirty-range invalidation should be layered on the source-range fold plan; the spike proves recomputation
  from bounded visible ranges, not a final incremental cache.
- Selection must remain raw UTF-16 source `NSRange`s. A production selection-normalization layer needs
  explicit leading/trailing hidden-edge semantics so arrow keys, shift-selection, mouse placement, and copy
  never stop inside hidden delimiters.
- IME remains non-negotiable. Before shipping, repeat Spike A with actual macOS Zhuyin/Pinyin input method
  event streams and with the real visual folding mechanism, not only `setMarkedText` plus attributes.
- If v1 uses TextKit layout-fragment customization or attachments instead of simple attributes, rerun Spike
  A/B/C against that mechanism. Attribute-only success does not automatically prove zero-width fragment or
  attachment behavior.
- Link folding must keep reveal semantics on the full `[text](url)` source range and keep copied text as
  raw Markdown.
- Partial folded-span copy is not specified by this spike beyond avoiding hidden delimiter caret stops;
  production needs an explicit policy before enabling visual selection over folded tokens.
- Defer tables, Mermaid/math, image attachments, and framed code fences until inline WYSIWYG is stable.

## 11. Production-core result — 2026-06-26

**Recommendation: PASS for development plumbing only.** The first production-core PR wires the
inline fold/reveal mechanism into EditorKit's existing visible-range highlight pipeline without adding
a user-facing WYSIWYG mode. Source text remains canonical, source-only and source+preview modes are
unchanged, and the app-level `⌘⇧P` cycle still only toggles the preview pane.

### Production approach

- `WYSIWYGFoldParser` is now a compatibility wrapper over `MarkdownSyntaxParser`; production uses the
  parser already held by the `MarkdownHighlightService` actor.
- Fold planning and syntax highlighting share one visible block parse through a combined visible parse
  API, avoiding the initial double-parse path that measured 60.700 ms on the 1 MB fold fixture.
- Fold/reveal remains derived from source `NSRange`s plus the current raw selection. Selection changes
  schedule recompute only when the non-user-facing fold presentation hook is enabled.
- Presentation is attribute-only and applied through the existing `MarkdownTextView.applyHighlightedText`
  path, which disables undo registration, rejects stale text, preserves selection/scroll, and skips while
  marked text exists.
- The hook is `MarkdownEditorView(..., _developmentPresentation: .inlineFoldReveal)`, defaulting to
  `.source`. The App does not pass it, it is not persisted, and it is intended for tests/development only.

### Constructs included/deferred

- Included in production presentation: headings, strong/emphasis, strikethrough, inline code, plus
  list/quote marker styling only.
- Link ranges remain in the pure fold model for offset/reveal validation, but production presentation
  does not fold links yet. Link folding stays blocked on a native selection/caret policy for hidden link
  chrome and partial folded-span copy.
- Still deferred: image thumbnails, fenced-code fragments, tables, Mermaid/math, MDX component rendering,
  attachments, and layout-fragment customization.

### Gate results

- **IME — PASS for automated production path.** `WYSIWYGIMESpikeTests` now applies production
  fold/reveal output from `MarkdownSyntaxHighlighter(..., developmentPresentation: .inlineFoldReveal)`
  before running the Zhuyin and Pinyin `setMarkedText` scripts. Fold attributes are skipped during active
  marked text and reapplied after commit without changing source text, marked range, or caret.
- **Undo — PASS.** `MarkdownEditorViewTests.testWYSIWYGUndoRecomputesFoldRevealStateWithoutUndoingPresentation`
  now uses the production fold presentation. Attribute state still does not enter undo/redo, stale
  presentation is rejected after undo, and recomputation follows current source plus selection.
- **Selection/copy — PASS for raw source semantics on included folds.**
  `WYSIWYGSelectionMappingSpikeTests.testProductionFoldPresentationCopyUsesRawBackingString` applies the
  production presentation to folded bold/strike spans and confirms STTextView copy returns raw Markdown.
  Pure link range mapping remains covered, but link presentation is deferred.
- **Performance — PASS after combined visible parse.** The production fold/highlight/apply probe on the
  1 MB fixture measured 20.706 ms during the full `make test` run, under the §12 50 ms visible-highlight
  budget. A targeted EditorKit rerun measured 21.206 ms, and existing typing hot-path samples stayed below
  1 ms max for Markdown/MDX triggers.

### Remaining blockers

- Run actual macOS Zhuyin/Pinyin input-method event streams before exposing WYSIWYG to users; current IME
  evidence is automated `setMarkedText`.
- Define and test native arrow-key, mouse, shift-selection, and partial folded-span copy semantics for
  hidden delimiter edges before enabling link folding or a user-facing WYSIWYG mode.
- Keep WYSIWYG out of persisted layout mode and the user-facing `⌘⇧P` cycle until a dedicated UI PR
  clears those remaining gates.

## 12. Native interaction gate result — 2026-06-26

**Recommendation: PARTIAL PASS; user-facing WYSIWYG remains blocked.** This PR adds production-path
STTextView tests for native selection, copy, and paste around the #38 development hook. It does not add
WYSIWYG to the app layout cycle, does not expose a user-facing mode, and does not expand visual folding
beyond headings, strong/emphasis, strikethrough, inline code, and list/quote marker styling.

### Issue tracking

- Issue #37 is closed as completed by PR #38. The remaining work is tracked as follow-up native
  interaction gates, not as unfinished production-core scope.
- `docs/codex-handoff.md` now marks PR #36 spikes and PR #38 production dev hook complete, with native
  interaction gates as the active Phase 2 goal.

### Native selection/caret evidence

- **Arrow movement — PASS for the current fallback policy.**
  `WYSIWYGNativeInteractionGateTests.testNativeArrowLandingInsideFoldedDelimiterRevealsInsteadOfTrapping`
  drives STTextView's native `moveRight` into a raw folded delimiter offset. The raw selection remains
  sane, and the next production presentation recompute reveals the touched span instead of leaving the
  caret inside hidden delimiter attributes.
- **Reverse shift-selection — PASS.**
  `testReverseShiftSelectionAcrossFoldedStrikeKeepsRawRangeAndRevealStateSane` uses native
  `moveLeftAndModifySelection` across `~~gone~~`, confirms the selected source range is exactly the raw
  Markdown span, confirms the selected folded region reveals, and confirms copy writes raw Markdown.
- **Selection across included folds — PASS for bold, strike, and inline code.**
  `testNativeShiftSelectionAcrossFoldedBoldStrikeAndInlineCodeCopiesRawMarkdown` extends native
  shift-selection from folded bold through strike and inline code, confirms all touched fold regions
  reveal, and confirms copy writes the selected raw Markdown.
- **Mouse/click-to-caret — PARTIAL PASS.**
  `testMouseLikeBoundaryCaretsRecomputeFoldedStateFromRawSelection` covers the raw boundary selections
  expected from click-to-caret near heading, bold, and inline-code delimiters. True pointer hit-testing
  against laid-out zero-width delimiter attributes is still manual-release evidence, not fully automated.

The accepted fallback policy for this development hook is conservative: native selection may enter raw
delimiter offsets, but any selection that touches a folded region reveals that region on the next
presentation pass. A later user-facing WYSIWYG PR can add delimiter-skipping/edge snapping, but it must
rerun these gates.

### Copy/paste policy

- **Policy:** copy is exact raw source selection. Entire folded spans copy delimiters, visible-content-only
  selections copy only content, and boundary selections copy exactly the Markdown characters included by
  the raw `NSRange`. The editor does not synthesize rendered/plaintext output from folded presentation.
- **Evidence:** `testPartialFoldedSpanCopyPolicyUsesExactRawSelection` covers entire folded bold/code/strike
  spans, visible bold content, and selections beginning or ending at bold fold boundaries.
- **Paste evidence:** `testPasteIntoFoldedAndRevealedRegionsMutatesBackingSourceOnly` pastes through
  STTextView's pasteboard read path into a folded boundary and a revealed inline-code content range. The
  backing string changes normally and no attachment or presentation-only placeholder text is inserted.

This policy is safe for the current attribute-only dev hook. Link visual folding remains deferred until
link chrome, destinations, and boundary selections have equivalent native coverage.

### Paste, accessibility, and performance evidence

- **Paste — PASS for backing-source mutation.**
  `testPasteIntoFoldedAndRevealedRegionsMutatesBackingSourceOnly` exercises STTextView pasteboard reads
  at a folded bold boundary and inside revealed inline-code content. Both edits mutate the raw backing
  string only and insert no object-replacement characters or presentation-only text.
- **Accessibility — PASS for raw value exposure in the development hook.**
  `testAccessibilityValueRemainsRawMarkdownSource` applies production fold/reveal attributes and confirms
  STTextView still reports `AXTextArea` with the exact raw Markdown source as its accessibility value.
  This is attribute-only accessibility evidence; any future layout-fragment, attachment, or user-facing
  WYSIWYG mode must rerun accessibility checks.
- **Large-doc performance — PASS.**
  `MarkdownEditorViewTests.testWYSIWYGVisibleRangeFoldRecomputeStaysUnderHighlightBudget` ran during the
  final `make test` pass on the 1 MB fixture and measured visible-range fold/highlight/apply at 21.468 ms,
  under the §12 50 ms budget.

### IME evidence

- Automated production-path IME coverage remains green:
  `WYSIWYGIMESpikeTests.testZhuyinAndPinyinMarkedTextRoundTripsAtFoldBoundaries` covers Zhuyin and Pinyin
  marked text at heading marker, bold, italic, and inline-code delimiter boundaries through
  `MarkdownSyntaxHighlighter(..., developmentPresentation: .inlineFoldReveal)`.
- Local input-source inspection found Traditional Chinese Zhuyin selected and enabled:
  `AppleSelectedInputSources` includes `com.apple.inputmethod.TCIM.Zhuyin`,
  `AppleEnabledInputSources` includes ABC plus TCIM Zhuyin, and
  `AppleCurrentKeyboardLayoutInputSourceID` returned `com.apple.keylayout.ZhuyinBopomofo`. A TIS input
  source query for Zhuyin/Pinyin IDs returned only `com.apple.inputmethod.TCIM.Zhuyin`; Pinyin did not
  appear in the installed or enabled input-source list on this machine. This is environment evidence
  only, not an actual composition-event run.
- **Actual macOS input-method event stream gate is not complete.** No committed automated test drives
  real TIS/input-context key events for both Zhuyin and Pinyin through the production development hook.
  Treat this as the primary blocker before any user-facing WYSIWYG mode.

### Remaining blockers

- Capture actual macOS Zhuyin and Pinyin event-stream evidence at heading, bold/italic, and inline-code
  boundaries, including composition, commit, caret stability, skipped fold attributes while marked text is
  active, and reapply after commit.
- Add true mouse hit-test evidence against the laid-out editor if the next PR changes delimiter hiding,
  adds edge snapping, or exposes WYSIWYG beyond tests.
- Keep link visual folding, image thumbnails, fenced-code fragments, tables, Mermaid/math, and MDX
  rendering deferred.
- Keep WYSIWYG out of persisted layout mode and the user-facing `⌘⇧P` cycle.

### Next PR recommendation

The next PR should be an actual macOS IME/manual-harness gate for the existing development hook. If that
passes for Zhuyin and Pinyin, follow with a narrow pointer hit-testing/selection-edge PR. User-facing
WYSIWYG should remain blocked until those pass.
