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

This document resolves the Phase 2 design open questions and approves the spike phase. The next
valid work item is **Spike A/B/C planning or execution**. Full WYSIWYG implementation remains blocked
until those spike results are recorded and accepted.

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
