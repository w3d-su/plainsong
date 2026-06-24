# Phase 2 — WYSIWYG Design (DRAFT)

> **Status: DRAFT — not approved.** Per agent.md §13, Phase 2 (Typora-style WYSIWYG) may begin only
> when M1–M5 are complete **and** this document is approved by the maintainer. This draft frames the
> architecture, the risk-reduction spikes, and the open decisions. Nothing in Phase 2 is implemented
> until this is signed off. Update agent.md's Decision Log when a decision here is accepted.
>
> Prerequisites not yet met: **M5 is not accepted** because the final M5 checklist sweep left
> unchecked manual blockers. Treat this as planning only.

## 1. Goal & non-goals

**Goal:** in-place WYSIWYG editing in the spirit of Typora — the rendered document IS the editing
surface; raw markdown delimiters are revealed only for the node the cursor is inside.

**Non-goals (Phase 2):** contentEditable / web-based editing (rejected — editor stays native TextKit 2);
replacing the two-pane source+preview mode (it stays behind the ⌘⇧P toggle forever); full MDX component
execution (still placeholder, Phase 3+).

## 2. Core architectural approach (from §13)

- **Stay on TextKit 2. No text mutation for rendering.** The source `String` remains the single model
  (same as Phase 1). WYSIWYG is achieved by *folding* tokens via layout/attributes, never by editing text.
- Parse (reuse the existing tree-sitter tree) → for each inline/block node:
  - **cursor/selection OUTSIDE the node →** apply "rendered" presentation: hide delimiter tokens
    (zero-width via TextKit 2 layout-fragment customization or attribute folding), apply real styles
    (heading scale, bold/italic traits), swap image links for `NSTextAttachment` thumbnails, render fences
    in a framed `NSTextLayoutFragment`.
  - **cursor ENTERS the node's range →** reveal the raw markdown for that node only (Typora behavior).
- The reveal/fold boundary is driven by selection changes, recomputed incrementally on the visible range.

## 3. Component plan (fold/reveal per construct)

| Construct | Rendered (folded) form | Reveal trigger | Risk |
|---|---|---|---|
| Headings | hide `#`s, scale text | caret on the line | low |
| Bold / italic / strike | hide delimiters, apply trait | caret inside span | medium (nested/adjacent spans) |
| Inline code | hide backticks, pill background | caret inside | low |
| Links | show link text, hide `[]()`; dim/underline | caret inside | medium (where does caret "enter"?) |
| Images | `NSTextAttachment` thumbnail | caret on line → raw | medium (async load, sizing) |
| Fenced code | framed `NSTextLayoutFragment`, syntax-highlighted | caret inside fence | high (custom fragment) |
| Lists / quotes | styled markers/indent | caret on line | low–medium |
| Tables | **initially stay RAW** + table helper (§6.3) | n/a | very high — defer |
| Mermaid / math | rendered fragment embedding a view | caret on block → raw | very high — defer or reuse preview |

Tables and mermaid/math in-place are the hardest; the draft proposes **keeping them raw in the first
Phase-2 release** (tables via the existing §6.3 helper), and revisiting after the core fold/reveal works.

## 4. Risk areas & spike plan (DO THESE FIRST, before any production WYSIWYG)

§13: "write exploratory tests early." These three spikes gate the rest of Phase 2. Each is a throwaway
branch with tests, reported back before committing to the architecture.

### Spike A — IME composition (NON-NEGOTIABLE)
- **Risk:** marked text (Chinese input) interacting with token folding/reveal can corrupt composition.
- **Spike:** fold/reveal a heading + bold span; drive Traditional Chinese **Zhuyin** and **Pinyin** marked
  text insertion at the fold boundary; assert no corruption, no caret jump, no premature commit.
- **Accept:** marked-text round-trips correctly at every change while folding is active; matches Phase 1
  IME behavior. If this can't be made correct, Phase 2 is blocked.

### Spike B — Undo coordination
- **Risk:** folding via attributes/layout must not pollute the undo stack; typing through a fold/reveal
  must remain one logical undo step (like Phase 1's native one-step undo).
- **Spike:** type, fold, edit inside a revealed node, undo/redo repeatedly; assert text + selection restore
  exactly and folding state recomputes (not stored in undo).
- **Accept:** undo/redo never leaves stale folded ranges or desynced text.

### Spike C — Selection across folded tokens
- **Risk:** selecting/extending across zero-width folded delimiters → wrong offsets, visual glitches,
  copy producing the wrong string.
- **Spike:** select across a folded bold span and a link; arrow-key and shift-select across boundaries;
  copy and assert the copied raw markdown is correct; click-to-place caret lands at a sane source offset.
- **Accept:** selection math maps cleanly to source offsets; copy yields raw markdown; no caret traps.

## 5. Mode behavior
- ⌘⇧P cycles: source+preview → source only → **WYSIWYG** (once it ships). Persisted across relaunch.
- Two-pane mode remains available indefinitely; WYSIWYG is additive, not a replacement.

## 6. Testing strategy (beyond the spikes)
- IME regression: Zhuyin/Pinyin marked text at every fold/reveal transition (highest priority).
- Fold/reveal unit tests on the pure boundary logic (which node range is revealed for a given selection).
- Performance: folding recompute stays within §12 typing-latency budget on the visible range only; never
  reparse/refold the whole document on a keystroke.
- Snapshot/visual tests for each rendered construct in light/dark.

## 7. Open questions (need maintainer decision)
- [ ] "Cursor enters a node" — exact boundary semantics for links (whole `[text](url)` vs just text)?
- [ ] Tables/mermaid/math: confirm "stay raw in first release" vs invest in custom fragments up front.
- [ ] Image thumbnails: max size, async-load placeholder, click behavior.
- [ ] Does WYSIWYG reuse the preview's KaTeX/mermaid output, or render natively? (reuse likely cheaper)
- [ ] Minimum viable Phase-2 scope to ship behind the toggle (which constructs in v1)?

## 8. Acceptance criteria
**For this design doc (the Phase-2 gate):** §7 open questions resolved; spike A/B/C plans approved;
v1 scope agreed; Decision Log entry added.
**For Phase 2 v1 (later):** the agreed construct set folds/reveals correctly; IME (Zhuyin/Pinyin) correct
at every change; undo/redo and cross-fold selection correct; typing latency within §12; two-pane mode
unaffected; ⌘⇧P cycle persists.

## 9. Proposed phased rollout within Phase 2
1. Spikes A/B/C (throwaway, gating). 2. Fold/reveal engine + low-risk constructs (headings, emphasis,
inline code, lists/quotes). 3. Links + image attachments. 4. Framed code fences. 5. (Stretch) tables /
mermaid / math fragments. Each is its own `phase2-*` PR; tables/mermaid only after 1–4 are solid.
