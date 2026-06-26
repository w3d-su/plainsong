# Phase 2 — WYSIWYG Design

> **Status: DESIGN GATE APPROVED FOR INLINE-FIRST V1 — production UI not implemented.** Per agent.md
> §13 and the 2026-06-26 Decision Log entry, Phase 2 may proceed only as a narrow inline-first
> production implementation after the spike gates below. This spike/validation PR does not ship
> user-facing WYSIWYG, does not add WYSIWYG to the ⌘⇧P cycle, and must not mutate source text for
> presentation.
>
> Gate scope: headings, emphasis/strike, inline code first; links only with selection/copy safety;
> images, fenced-code custom fragments, tables, Mermaid, math, and real MDX rendering are deferred.

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
- [x] "Cursor enters a node" — links reveal on the full `[text](url)` source range. Production links stay
  gated on selection/copy safety.
- [x] Tables/mermaid/math: defer; keep raw in inline-first v1.
- [x] Image thumbnails: defer; no attachment work in inline-first v1.
- [x] Real Mermaid/math/MDX rendering: defer; do not reuse preview output in inline-first v1.
- [x] Minimum viable Phase-2 scope: headings, emphasis/strike, inline code first; links next after the
  selection spike remains green in the production mechanism.

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

## 10. Spike A/B/C/D result — 2026-06-26

**Recommendation: GO for the next production PR, limited to an inline-first fold/reveal engine.** The
spike validates the core safety premise for headings, emphasis/strike, inline code, and inline links:
source text remains canonical, fold/reveal is representable as pure source ranges, and attribute-only
presentation can be recomputed without entering undo or corrupting automated marked-text or
selection/copy state.

This is **not approval to ship production WYSIWYG UI** and does not add WYSIWYG to the user-facing
⌘⇧P cycle. The next PR should wire the real mechanism behind non-user-facing development plumbing and
rerun these gates before any user-visible mode change.

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
- **Spike B — CONDITIONAL PASS for attribute-only presentation.** `MarkdownEditorViewTests` verifies presentation
  attributes do not enter undo/redo, stale presentation is rejected after undo, and a type → fold → reveal
  → edit-inside-revealed-node → undo/redo loop repeatedly restores source text, selection, and recomputed
  fold state. Redo selection currently follows STTextView native behavior by selecting the reinserted
  character; confirm that UX in the production PR.
- **Spike C/D — CONDITIONAL PASS for raw-range mapping and copy.** `WYSIWYGSelectionMappingSpikeTests` proves folded
  bold/link selections normalize to raw Markdown ranges, visible caret offsets skip hidden delimiter
  interiors in the pure projection, STTextView copy uses the raw backing string when delimiters are only
  visually hidden by attributes, and the prototype link reveal range is the full `[text](url)` source span.
  This is pure mapping plus programmatic copy evidence, not real mouse/arrow-key event evidence. Reverse
  shift-selection, native mouse placement, and partial folded-span copy policy remain production-gate checks.

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
- Defer tables, mermaid/math, image attachments, and framed code fences until inline WYSIWYG is stable.
