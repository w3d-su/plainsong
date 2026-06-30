# Phase 2 — WYSIWYG Design Gate

> **Status: APPROVED FOR PHASE 2 SPIKES.** M1–M5 are accepted, so Phase 2 may begin as
> design validation and risk-reduction spikes. This approval does **not** authorize a full
> WYSIWYG implementation PR. Production implementation starts only after the approved spikes
> pass and their results are recorded here or in follow-up design notes.
>
> Scope discipline: Phase 2 stays native TextKit 2. Source text remains the only model.
> The two-pane source+preview mode remains available indefinitely.
>
> Current note (2026-06-27): §§12-14 are historical gate records. Native input,
> selection, and pointer gates are complete as of §§16-19; WYSIWYG is available only as an
> off-by-default Experimental mode, and stable/default promotion remains blocked by
> `docs/wysiwyg-release-checklist.md`.

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

### Historical blockers at this point (superseded by §§12-19)

- Run actual macOS Zhuyin/Pinyin input-method event streams before exposing WYSIWYG to users; current IME
  evidence is automated `setMarkedText`.
- Define and test native arrow-key, mouse, shift-selection, and partial folded-span copy semantics for
  hidden delimiter edges before enabling link folding or a user-facing WYSIWYG mode.
- Keep WYSIWYG out of persisted layout mode and the user-facing `⌘⇧P` cycle until a dedicated UI PR
  clears those remaining gates.

## 12. Historical native interaction gate result — 2026-06-26

**Historical recommendation: PARTIAL PASS, superseded by §§13-19.** PR #41 added production-path
STTextView tests for native selection, copy, and paste around the #38 development hook. At that point,
the follow-up actual-IME gate proved macOS Traditional Chinese Zhuyin event streams through the same
hook, but Pinyin remained unrun on this machine because the Pinyin input methods were installed but not
enabled or selectable. Later sections record the completed Pinyin, pointer, mechanism, edge-snapping,
and Experimental mode gates. No PR in this sequence added WYSIWYG to the app layout cycle, exposed a
user-facing mode, or expanded visual folding beyond headings, strong/emphasis, strikethrough, inline
code, and list/quote marker styling.

### Issue tracking

- Issue #37 is closed as completed by PR #38. The remaining work is tracked as follow-up native
  interaction gates, not as unfinished production-core scope.
- `docs/codex-handoff.md` now marks PR #36 spikes and PR #38 production dev hook complete, with native
  interaction gates as the active Phase 2 goal.

### Native selection/caret evidence

- **Arrow movement — PASS.**
  `WYSIWYGNativeInteractionGateTests.testNativeArrowIntoFoldedDelimiterSnapsToInnerEdgeAndReveals`
  drives STTextView's native `moveRight` toward a raw folded delimiter offset. The raw selection remains
  sane, the touched span reveals, and the caret never rests inside hidden delimiter attributes. As of
  2026-06-27 the caret-rest behavior is upgraded from reveal-only to delimiter edge-snapping (see §17).
- **Reverse shift-selection — PASS.**
  `testReverseShiftSelectionAcrossFoldedStrikeKeepsRawRangeAndRevealStateSane` uses native
  `moveLeftAndModifySelection` across `~~gone~~`, confirms the selected source range is exactly the raw
  Markdown span, confirms the selected folded region reveals, and confirms copy writes raw Markdown.
- **Selection across included folds — PASS for bold, strike, and inline code.**
  `testNativeShiftSelectionAcrossFoldedBoldStrikeAndInlineCodeCopiesRawMarkdown` extends native
  shift-selection from folded bold through strike and inline code, confirms all touched fold regions
  reveal, and confirms copy writes the selected raw Markdown.
- **Historical mouse/click-to-caret — PARTIAL PASS, closed by §14.**
  `testMouseLikeBoundaryCaretsRecomputeFoldedStateFromRawSelection` covers the raw boundary selections
  expected from click-to-caret near heading, bold, and inline-code delimiters. At this point true pointer
  hit-testing against laid-out zero-width delimiter attributes was still manual-release evidence, not fully
  automated; §14 records the later automated pointer pass.

The accepted fallback policy for this development hook is conservative: native selection may enter raw
delimiter offsets, but any selection that touches a folded region reveals that region on the next
presentation pass. A later user-facing WYSIWYG PR can add delimiter-skipping/edge snapping, but it must
rerun these gates. (Edge-snapping for collapsed carets landed 2026-06-27 — see §17 — and reran these
gates; selection still enters raw delimiter offsets so copy stays exact raw Markdown.)

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
- A reusable opt-in actual-IME harness now exists in
  `WYSIWYGActualIMEEventGateTests`. It is skipped during normal `make test`; run
  `PLAINSONG_RUN_ACTUAL_IME=1 swift test --filter WYSIWYGActualIMEEventGateTests/testActualZhuyinEventStreamAtFoldBoundaries`
  from `Packages/EditorKit` to open a focused AppKit editor window, select the TIS input source, and send
  physical-key `CGEvent.postToPid` events through STTextView's `keyDown -> inputContext` path. The harness
  keeps the input-client window alive until process exit because closing it immediately after TCIM
  composition can crash IMK teardown under xctest.
- Local input-source inspection found Traditional Chinese Zhuyin selected and enabled:
  `AppleSelectedInputSources` includes `com.apple.inputmethod.TCIM.Zhuyin`,
  `AppleEnabledInputSources` includes ABC plus TCIM Zhuyin, and
  `AppleCurrentKeyboardLayoutInputSourceID` returned `com.apple.keylayout.ZhuyinBopomofo`. TIS enabled
  source lookup found `com.apple.inputmethod.TCIM.Zhuyin (Zhuyin - Traditional)`.
- **Actual Zhuyin event stream — PASS.** The opt-in command above passed on 2026-06-26 using
  `com.apple.inputmethod.TCIM.Zhuyin (Zhuyin - Traditional)`. It drove the physical key sequence
  `w -> 9 -> 6 -> space -> return -> return` through heading, bold, italic, and inline-code fold
  boundaries. The run confirmed no source composition corruption, no caret escape from the marked range,
  no premature commit, skipped fold/reveal application while marked text was active, and successful
  presentation reapply after commit.
- The actual Zhuyin run exposed and fixed a production-path commit corruption risk: while marked text is
  active, TCIM Return/space selection keys can update the input context and still fall through to normal
  STTextView interpretation. `MarkdownSTTextView` now reserves space, Return, and keypad Enter for the
  input context while marked text is active so commit/candidate keys cannot also insert ordinary whitespace
  or newlines.
- **Historical Actual Pinyin pre-Goal-3 state — superseded.** TIS `includeAllInstalled=true`
  found `com.apple.inputmethod.SCIM.ITABC (Pinyin - Simplified)` and
  `com.apple.inputmethod.TCIM.Pinyin (Pinyin - Traditional)`, but TIS
  `includeAllInstalled=false` found no enabled/selectable Pinyin input method. Direct
  `TISSelectInputSource` attempts for both Pinyin input methods returned `-50`, so the opt-in Pinyin test
  skips with manual enablement instructions. To finish the gate locally, enable Pinyin in System Settings
  > Keyboard > Text Input > Edit > + > Chinese, then rerun
  `PLAINSONG_RUN_ACTUAL_IME=1 swift test --filter WYSIWYGActualIMEEventGateTests/testActualPinyinEventStreamAtFoldBoundariesWhenEnabled`
  from `Packages/EditorKit`. This state was superseded by §13; Pinyin is no longer an active blocker.

### Historical blockers at this point (superseded by §§13-19)

- Capture actual macOS Pinyin event-stream evidence at heading, bold/italic, and inline-code boundaries
  after enabling a Pinyin input method on the runner machine.
- Add true mouse hit-test evidence against the laid-out editor if the next PR changes delimiter hiding,
  adds edge snapping, or exposes WYSIWYG beyond tests.
- Keep link visual folding, image thumbnails, fenced-code fragments, tables, Mermaid/math, and MDX
  rendering deferred.
- Keep WYSIWYG out of persisted layout mode and the user-facing `⌘⇧P` cycle.

### Historical next PR recommendation (completed by §§13-14)

The next PR should enable/run the opt-in actual Pinyin harness on a machine with Pinyin enabled. If Pinyin
passes, follow with a narrow pointer hit-testing/selection-edge PR. User-facing WYSIWYG should remain
blocked until those pass.

## 13. Actual Pinyin event-stream gate result — 2026-06-26

**Recommendation: PASS for actual Pinyin; user-facing WYSIWYG remains blocked.** The opt-in actual-IME
harness now drives a real macOS Traditional Chinese Pinyin input method through the production
`_developmentPresentation: .inlineFoldReveal` hook at heading, bold, italic, and inline-code fold
boundaries. With both actual Zhuyin (§12) and actual Pinyin event streams passing, IME is no longer a gate
blocker. WYSIWYG stays out of the user-facing `⌘⇧P` cycle and out of persisted layout state until the
remaining native pointer hit-test and release-checklist gates pass. No construct scope was expanded and
link visual folding remains deferred.

### Pinyin input-source environment

- Enabled/selected source during the passing run: `com.apple.inputmethod.TCIM.Pinyin`
  (`Pinyin – Traditional`), type `TISTypeKeyboardInputMode`.
- Pinyin was installed but not enabled on this machine, reproducing PR #42's state: TIS
  `includeAllInstalled=false` found no enabled Pinyin source, and direct `TISSelectInputSource` returned
  `-50`. Enabling it programmatically with `TISEnableInputSource(com.apple.inputmethod.TCIM.Pinyin)`
  returned `0`, after which the source selected with `0`.
- `com.apple.inputmethod.SCIM.ITABC` (`Pinyin – Simplified`) reported enable `0` but still returned `-50`
  on select in this environment, so the Traditional Pinyin IME was used. Either Simplified or Traditional
  satisfies the gate.
- The two plain Pinyin keyboard *layouts* (`com.apple.keylayout.PinyinKeyboard`,
  `com.apple.keylayout.TraditionalPinyinKeyboard`) match the harness CJK name filter but are
  `TISTypeKeyboardLayout` and never produce marked text. The harness now selects only composition-capable
  input methods so it can never pick a keyboard layout for the IME gate. Those two layouts were disabled
  after the run, and the current keyboard source was restored to `com.apple.keylayout.ABC`; the
  `TCIM.Pinyin` and `TCIM.Zhuyin` input methods remain enabled.

### Pinyin evidence

- `PLAINSONG_RUN_ACTUAL_IME=1 swift test --filter WYSIWYGActualIMEEventGateTests/testActualPinyinEventStreamAtFoldBoundariesWhenEnabled`
  passed (27.2 s) and is reproducible across repeated runs.
- Event path: physical `CGEvent.postToPid` key presses into the xctest process, through
  `MarkdownSTTextView` → `STTextView.keyDown` → `NSTextInputContext`.
- Composition script `t → a → i` produced marked text `t`/`ta`/`tai`; `space` committed the first
  candidate `太` (the deterministic toneless-"tai" top candidate in the Traditional Pinyin IME, stable
  across runs). This is the expected, legitimate difference from the Zhuyin ㄊㄞˊ tone-2 script, which
  commits 台/臺; the Pinyin fixture now accepts 太/台/臺.
- Verified at every fold boundary (heading; bold/italic/inline-code before and after both the opening and
  the closing delimiter): no source composition corruption, no caret escape from the marked range, no
  premature commit, fold/reveal attributes skipped while marked text is active, fold attributes never
  cover the active marked range, and presentation reapplies after commit. The PR #42 commit-key guard
  (space/Return/keypad-Enter reserved for the input context while marked text exists) held for Pinyin.
- Cold-start note: the first run after enabling the IME produced no composition because the TCIM Pinyin
  server was not yet warm (it logged `error messaging the mach port for IMKCFRunLoopWakeUpReliable`).
  Reruns once the server is warm pass deterministically; re-run the gate once if the IME has never been
  activated in the session.

### Harness change

- `ActualIMEInputSource` now records `kTISPropertyInputSourceType`, and `enabled(matching:)` selects only
  composition-capable input methods (`TISTypeKeyboardInputMode` /
  `TISTypeKeyboardInputMethodWithoutModes` / `TISTypeKeyboardInputMethodModeEnabled`), never a
  `TISTypeKeyboardLayout`. This keeps Zhuyin selecting `com.apple.inputmethod.TCIM.Zhuyin` (re-verified
  passing) and makes Pinyin deterministically select the real IME instead of a same-named keyboard layout.

### Historical blockers at this point (superseded by §§14-19)

- Add true mouse hit-test / pointer selection-edge evidence against the laid-out editor before exposing
  WYSIWYG beyond tests or enabling delimiter edge-snapping/link folding.
- Keep link visual folding, image thumbnails, fenced-code fragments, tables, Mermaid/math, and MDX
  rendering deferred.
- Keep WYSIWYG out of persisted layout mode and the user-facing `⌘⇧P` cycle until the pointer gate and a
  written release checklist pass.

### Next PR recommendation

The next PR should add a narrow native pointer hit-testing / selection-edge gate against the production
development hook (click-to-caret near hidden delimiters and drag selection across folded spans). After
that passes, a separate PR can specify the user-facing WYSIWYG release checklist. User-facing WYSIWYG
remains blocked until both land.

## 14. Native pointer hit-testing / selection-edge gate result — 2026-06-26

**Recommendation: PASS for the attribute-only dev hook's reveal-on-touch policy; user-facing WYSIWYG
remains blocked.** `WYSIWYGNativePointerGateTests` lays the production `_developmentPresentation:
.inlineFoldReveal` editor out in a real `NSWindow`, folds the inline delimiters to ~zero width, and
dispatches real `NSEvent` left-mouse-downs at the on-screen position of folded content. The click target
comes from `firstRect(forCharacterRange:)` and the resulting caret comes from STTextView's own
`mouseDown → caretLocation(interactingAt:)` hit-test, so this is true pointer hit-testing against the
laid-out hidden delimiters — closing the PR #41 "mouse/click-to-caret PARTIAL PASS" gap. No construct
scope changed, link folding stays deferred, and the App still never passes the hook.

### Pointer hit-testing evidence

- **Heading marker — PASS.** `testPointerClickOnFoldedHeadingContentRevealsMarkerWithoutTrap` clicks the
  rendered heading text while the `# ` marker is folded: the caret lands on the heading line, the marker
  reveals on the next presentation pass, and the caret is never inside a still-folded delimiter. Clicking
  the body paragraph leaves the heading folded.
- **Bold / strike / inline-code content — PASS.**
  `testPointerClickAcrossFoldedInlineDelimitersPlacesSaneCaretAndReveals` clicks the content word between
  each construct's folded delimiters; the span reveals and the caret is sane. Clicking the trailing word
  leaves the span folded — the caret never gets stuck inside the now-hidden closing delimiter.
- **Delimiter-edge boundary clicks — PASS.**
  `testPointerBoundaryClicksAtFoldedDelimiterEdgesDoNotTrapCaret` clicks the leading edge of the first
  content character (abuts the hidden opening delimiter) and the trailing edge of the last content
  character (abuts the hidden closing delimiter) for bold, strike, and inline code. Each boundary click
  reveals the span and never traps the caret inside a folded delimiter.
- **No-trap invariant.** Every click outcome is checked against a precise invariant: for the resulting
  caret, no still-folded region's delimiter range contains the caret offset. This holds structurally
  (delimiters are a subset of the reveal range, so a caret inside a delimiter always reveals it) and is
  confirmed concretely from real click results.

### Drag selection evidence

- **PASS.** `testPointerDragSelectionAcrossFoldedSpansKeepsRawRangeAndCopy` anchors a pointer click inside
  folded bold and pointer-extends the selection (shift-click — the same hit-test + `updateTextSelection`
  path a drag uses) into folded inline code, crossing the hidden bold/strike/code delimiters. The selected
  source range is sane and non-empty, copy returns the exact raw Markdown for the range (the folded `**`,
  `~~`, and `` ` `` delimiters are included verbatim, not skipped or synthesized), every touched span
  reveals on the next presentation pass, and re-applying that presentation preserves the pointer-extended
  selection.
- AppKit's raw `mouseDragged` delta plumbing is internal and was not synthesized; pointer-extend
  (shift-click) drives the identical hit-test + selection-update path with real events, so it is a faithful
  proxy for the drag endpoint mapping that this gate cares about. Keyboard shift-selection across the same
  folded spans was already covered in §12.

### Edge policy decision

- **Reveal-on-touch is sufficient for the attribute-only development hook; no delimiter edge-snapping is
  required at this layer.** Because a caret that touches any part of a span's reveal range reveals the
  whole span (delimiters included), a pointer click can momentarily resolve to a hidden-delimiter offset
  but the very next presentation pass makes that delimiter visible. There is therefore no caret trap, and
  copy/selection always operate on raw source offsets. Adding edge-snapping now would be redundant for the
  dev hook and would complicate the raw-offset selection model the other gates rely on.
- **A user-facing WYSIWYG mode should still add edge-snapping and must rerun this gate**, because edge
  snapping is a UX refinement (avoiding a one-frame reveal flicker and making arrow/click landing feel
  intentional) rather than a correctness fix. It belongs in the user-facing PR, not the dev hook.
- **Mechanism caveat (superseded by §16).** The pointer-gate implementation used `baselineOffset(-1000)` plus a
  0.1 pt clear font. This makes a *single folded line* lay out as an ~1013 pt-tall text fragment. It does
  not trap the caret, but in a multi-line document the extreme fragment geometry distorts the viewport
  (an exhaustive every-glyph hit-test sweep was abandoned because folded lines pushed sibling lines
  outside the visible window). A user-facing WYSIWYG should move to a cleaner zero-width mechanism
  (`NSTextLayoutFragment` customization or attachment-based hiding) and rerun the IME, selection, and this
  pointer gate against that mechanism, per §10/§11 constraints.

### Historical user-facing status after this gate

Yes. This PR adds pointer-gate tests only. The App does not pass `_developmentPresentation:
.inlineFoldReveal`, no `⌘⇧P` exposure or persisted WYSIWYG layout mode was added, construct scope is
unchanged, and link visual folding stays deferred.

### Next PR recommendation

The remaining native interaction gates are complete for the attribute-only hook (IME — §12/§13, native
keyboard selection/copy/paste/accessibility — §12, and pointer/selection-edge — §14). The next PR should
specify the **user-facing WYSIWYG release checklist** (the cleaner zero-width fold mechanism, edge
snapping, the `⌘⇧P` cycle entry and persisted layout mode, and a gate-rerun matrix), and only then begin
exposing WYSIWYG. WYSIWYG stays blocked until that checklist is written and green.

## 15. User-facing WYSIWYG release checklist — 2026-06-26

**The release checklist now exists: see [`docs/wysiwyg-release-checklist.md`](wysiwyg-release-checklist.md).**
It is the single blocking gate list for exposing WYSIWYG to users and supersedes the ad-hoc "next PR"
notes above. WYSIWYG stays behind `_developmentPresentation: .inlineFoldReveal` until every checkbox in
that file is green with linked evidence.

The checklist is organized as:

- **A — Zero-width fold mechanism replacement.** Replace `baselineOffset(-1000)` (R18). The final mechanism
  is the TextKit 2 content-storage paragraph projection described in §16. `NSTextLayoutFragment`
  customization was attempted but not used with STTextView 2.3.10, and the attachment fallback was not
  needed. Tiny-font/kern-only, TextKit 1 glyph suppression, and real text deletion remain rejected.
- **B — Gate-rerun matrix.** Every native gate already proven against the dev-hook mechanism (IME Zhuyin/
  Pinyin, keyboard arrow/shift-selection, pointer click + drag, copy, paste, accessibility, large-doc
  performance, undo/redo, source-only/source+preview regression) has now rerun against the §A mechanism,
  plus the new layout-geometry sanity gate that closes R18.
- **C — UX policy.** Reveal-on-touch is retained; **edge-snapping** of the caret near hidden delimiters is
  now required for the user-facing mode (it was not needed for the dev hook); selection may still span raw
  delimiter offsets (that is how copy stays exact raw Markdown); copy policy stays exact raw Markdown; link
  visual folding stays deferred behind its own sub-gate.
- **D — Mode integration.** `⌘⇧P` becomes a three-state cycle (source+preview → source-only → WYSIWYG); the
  persisted layout value becomes a three-state enum with migration from the legacy
  `Plainsong.preview.isVisible` boolean; a kill switch + deterministic fallback to source-only handles
  mechanism failure/disable; WYSIWYG ships behind an off-by-default **Experimental** label until the
  checklist is fully green.
- **E — Construct scope.** Unchanged inline-first scope; images/fences/tables/Mermaid/math/MDX rendering
  and link visual folding stay deferred.

### Next PR recommendation (superseded by §16)

The cleaner zero-width fold mechanism prototype is now complete. User-facing mode integration (§C/§D) still
comes only after delimiter edge-snapping, the `⌘⇧P` cycle entry, persistence migration, recovery behavior,
and Experimental labeling are implemented and tested.

## 16. Zero-width fold mechanism result — 2026-06-26

The replacement mechanism is a TextKit 2 `NSTextContentStorageDelegate` paragraph projection, implemented
behind the existing non-user-facing `_developmentPresentation: .inlineFoldReveal` hook. When a paragraph
contains folded delimiter marker attributes, EditorKit returns an `NSTextParagraph` copy for layout where
only those delimiter characters are replaced by equal-length U+200B runs. The backing `NSTextStorage.string`
remains exact raw Markdown, so copy, paste, undo/redo, and accessibility continue to operate on source
offsets. No attachment path is used, so no U+FFFC can leak into copy, `AXValue`, or source text.

The originally preferred `NSTextLayoutFragment` customization was prototyped but not chosen for the pinned
STTextView 2.3.10 integration. STTextView owns `textLayoutManager.delegate` and supplies
`STTextLayoutFragment`; taking that delegate directly would break STTextView's fragment chain. A public
custom line-fragment prototype also did not reliably drive TextKit's segment / `firstRect` hit-testing path,
which made native pointer placement unsafe. The content-storage projection keeps STTextView's fragment
delegate intact and stays fully on TextKit 2.

Because the layout paragraph differs from the raw backing paragraph, `MarkdownSTTextView` adds narrow
WYSIWYG-only pointer and composed-character-aware keyboard adapters while the projection delegate is
installed. Source-only and source+preview paths do not install the delegate and remain unchanged. The old
`baselineOffset(-1000)` + 0.1 pt clear-font mechanism is removed from the implementation.

Checklist §A and §B are green against this mechanism: the opt-in actual Zhuyin/Pinyin IME event stream,
keyboard arrow and reverse shift-selection gates, true pointer click/drag gates, exact raw copy, paste,
accessibility, undo/redo, source-only/source+preview regression, and the new B13 layout-geometry sanity test
all pass. B13 verifies folded-line height is approximately the unfolded-line height and that folded lines do
not push sibling lines out of the viewport, so R18 is closed. The large-document WYSIWYG fold/highlight/apply
measurement is 26.964 ms on the 1 MB fixture, recorded in `docs/perf-log.md`.

User-facing WYSIWYG remains blocked. This mechanism PR does not expose WYSIWYG in `⌘⇧P`, does not add a
persisted WYSIWYG layout mode, does not enable link visual folding, and does not add images, fenced-code
custom fragments, tables, Mermaid/math widgets, or real MDX rendering.

## 17. Delimiter edge-snapping result — 2026-06-27

**Recommendation: PASS for the §C.2-§C.4 edge-snapping / selection / copy gates; user-facing WYSIWYG
remains blocked by §D mode integration.** Behind the existing `_developmentPresentation:
.inlineFoldReveal` hook, a *collapsed* caret that would rest strictly inside a folded (zero-width)
delimiter now snaps to the delimiter-inner boundary in the same pass, replacing the prior reveal-only
fallback for caret rest. No construct scope changed, link visual folding stays deferred, the App still
never passes the hook, and no persisted WYSIWYG layout mode was added.

### Mechanism

- `WYSIWYGCaretSnap.snap(offset:foldedDelimiterRanges:preferring:)` is a pure function: it returns the
  offset unchanged unless it is strictly interior to a folded run, in which case it snaps to that run's
  edge (`.forward` → trailing, `.backward` → leading, `.nearest` → nearer edge, tie → leading).
- `MarkdownSTTextView.wysiwygFoldedDelimiterRange(containingInterior:)` reads the live
  `foldedDelimiterAttribute` runs from the backing text storage with a bounded
  `longestEffectiveRange` scan, so snapping reflects exactly what is currently hidden and stays O(1) on
  the caret-movement path.
- Keyboard: `applyWYSIWYGComposedCharacterMovement` snaps the destination of collapsed-caret
  `moveLeft`/`moveRight` (direction-of-travel). The extending (shift-selection) branch is untouched.
- Pointer: the non-shift `mouseDown` branch snaps the hit-test result with `.nearest`. The shift
  (pointer-extend/drag) branch is untouched.

### Why caret-only, never selection

Edge-snapping only adjusts where a collapsed caret rests. Selections still span raw UTF-16 source
offsets — that is how copy stays exact raw Markdown (entire folded spans include their delimiters,
boundary selections copy the exact `NSRange`). Snapping reads the same fold attributes the zero-width
projection uses, so the backing `String` is never mutated.

### Asymmetry note

With reveal-on-touch, a forward step toward an *opening* delimiter usually stops at the span's leading
boundary (which reveals it) before reaching the delimiter interior, so opening-edge snapping mainly
fires when the fold state lags the caret (the realistic async case). A leftward step from just after a
span lands inside the *closing* delimiter first (the right reveal boundary sits outside the span), so
closing-edge snapping fires on the natural traversal. Both directions are covered by tests.

### Evidence

- **Pure function — PASS.** `WYSIWYGEdgeSnappingGateTests.testSnap*` cover forward/backward/nearest
  snapping, the even-interior tie-break, run edges and outside offsets left unchanged, and single-char
  delimiters (no interior) left unchanged.
- **Keyboard — PASS.** `testArrowRightIntoFoldedBoldOpeningDelimiterSnapsToContentStart`,
  `testArrowLeftIntoFoldedBoldClosingDelimiterSnapsToContentEnd`,
  `testArrowIntoFoldedStrikeOpeningDelimiterSnapsToContentStart`,
  `testArrowIntoFoldedStrikeClosingDelimiterSnapsToContentEnd`,
  `testArrowRightIntoFoldedHeadingMarkerSnapsToContentStart`, and
  `testArrowAcrossFoldedInlineCodeSingleBacktickPlacesCaretAtContentWithoutTrap` drive real
  `moveLeft`/`moveRight` and assert the caret lands on the content boundary and never inside a folded
  delimiter. The repurposed
  `WYSIWYGNativeInteractionGateTests.testNativeArrowIntoFoldedDelimiterSnapsToInnerEdgeAndReveals`
  proves the same on the bold span end-to-end with reveal.
- **Pointer — PASS.** `testPointerCaretSnapResolvesHiddenDelimiterOffsetToVisibleBoundary` and
  `testRealPointerClicksAtFoldedDelimiterEdgesLandOnVisibleBoundary` (real `NSEvent` left-mouse-downs at
  the leading and trailing edges of folded bold/strike/inline-code content) confirm the click caret
  rests on a visible boundary, never inside a folded delimiter.
- **Selection/copy — PASS.** `testShiftSelectionAcrossFoldedDelimitersStillCopiesExactRawMarkdown`
  shift-selects across folded `**bold**` and copies it verbatim, and the existing
  `WYSIWYGNativePointerGateTests.testPointerDragSelectionAcrossFoldedSpansKeepsRawRangeAndCopy` remains
  green, proving snapping never clamps selections.
- **Composed characters — PASS.** `testComposedCharacterMovementStaysValidWithSnappingEnabled` and the
  existing `WYSIWYGNativeInteractionGateTests.testWYSIWYGMoveLeftRightSkipsEmojiComposedCharacterAndCJKBoundaries`
  confirm emoji/surrogate-pair and CJK movement endpoints stay on composed-character boundaries with
  snapping enabled.
- **Performance — PASS.** Snapping is on the caret-movement path, not the highlight path; the
  large-document WYSIWYG fold/highlight/apply probe stayed at 25.348 ms on the 1 MB fixture during the
  full `make test` run, under the §12 50 ms budget.

### Remaining blockers (superseded by §18)

- Implement §D mode integration: the three-state `⌘⇧P` cycle, the persisted layout enum + migration
  from `Plainsong.preview.isVisible`, the kill switch / deterministic `.sourceOnly` recovery, and the
  off-by-default Experimental label. This lands in §18.
- Keep link visual folding, image thumbnails, fenced-code fragments, tables, Mermaid/math, and MDX
  rendering deferred.
- Keep WYSIWYG off by default and Experimental until §F is green.

## 18. WYSIWYG mode-integration result — 2026-06-27

**Recommendation: PASS for the automated §D AppState/persistence/recovery gates; WYSIWYG remains
off by default behind an Experimental setting.** The App now has an explicit `EditorLayoutMode`
enum with `.sourcePreview`, `.sourceOnly`, and `.wysiwyg`. The legacy
`Plainsong.preview.isVisible` boolean migrates once to the new persisted enum
(`true → .sourcePreview`, `false → .sourceOnly`), preserving existing layouts.

### Mode and flag behavior

- `⌘⇧P`/toolbar/menu plumbing uses one AppState cycle: when Experimental WYSIWYG is enabled and the
  editor mechanism is healthy, the cycle is source+preview → source-only → WYSIWYG → source+preview.
- When Experimental WYSIWYG is disabled (the default), the cycle stays source+preview ↔ source-only and
  never lands on a dead WYSIWYG stop.
- A persisted `.wysiwyg` value read while the flag is disabled resolves deterministically to
  `.sourceOnly` and rewrites the persisted layout to `.sourceOnly`.
- Source-only and source+preview never pass `_developmentPresentation: .inlineFoldReveal`; WYSIWYG passes
  it only when the Experimental flag is enabled, the mode is `.wysiwyg`, and no mechanism failure has
  been recorded.

### Recovery and scope

`MarkdownSTTextView` now reports whether the TextKit 2 content-storage projection could be installed.
If enabling the WYSIWYG mechanism fails, AppState records/logs the recovery reason and falls back to
`.sourceOnly` without changing document text. Source text remains canonical, copy remains exact raw
Markdown, and no source mutation path was added.

This PR does not enable link visual folding and does not add image thumbnails, fenced-code custom
fragments, tables, Mermaid/math widgets, or real MDX rendering. Those constructs remain deferred.

### Evidence

- `AppStateTests.testLayoutModeMigratesLegacyVisiblePreviewPreference`
- `AppStateTests.testLayoutModeMigratesLegacyHiddenPreviewPreference`
- `AppStateTests.testLayoutModeCycleSkipsWYSIWYGWhenExperimentalFlagIsDisabled`
- `AppStateTests.testLayoutModeCycleIncludesWYSIWYGWhenExperimentalFlagIsEnabled`
- `AppStateTests.testPersistedWYSIWYGFallsBackToSourceOnlyWhenExperimentalFlagIsDisabled`
- `AppStateTests.testWYSIWYGMechanismFailureFallsBackToSourceOnlyWithoutChangingText`
- `AppStateTests.testSourceModesNeverUseWYSIWYGPresentationEvenWhenExperimentalFlagIsEnabled`

## 19. Experimental WYSIWYG manual sign-off — 2026-06-27

**Recommendation: PASS for off-by-default Experimental sign-off; stable/default promotion remains
blocked.** The Debug app was launched after PR #49 and manually verified against the release checklist
UI gates. WYSIWYG remains available only through the Settings toggle, and turning that toggle off while
in WYSIWYG falls back to source-only without changing the backing Markdown text.

### Manual UI evidence

- **Settings label/default — PASS.** Settings > Editor showed `WYSIWYG mode (Experimental)` with value `0`
  before enabling; the `Plainsong.settings.experimentalWYSIWYGEnabled` key was absent/false.
- **Disabled cycle — PASS.** With the flag off, `⌘⇧P` cycled only
  `sourcePreview -> sourceOnly -> sourcePreview`. The View menu labels were `Show Source Only` and
  `Show Preview`; toolbar labels were `Source Only` and `Preview`. Neither control landed on WYSIWYG.
- **Enabled cycle — PASS.** With the flag on, `⌘⇧P` cycled
  `sourcePreview -> sourceOnly -> wysiwyg -> sourcePreview`. The View menu and toolbar reflected the
  current next action: `Show Source Only` / `Source Only`, then
  `Show WYSIWYG (Experimental)` / `WYSIWYG`, then `Show Source + Preview` / `Source + Preview`.
- **Inline fold/reveal — PASS.** In WYSIWYG there was no preview pane, the heading marker was folded while
  the raw backing value still contained `# Heading`, and the link remained raw as
  `[link](https://example.com)`. This confirms WYSIWYG is using the inline fold/reveal path and link
  visual folding remains off.
- **Disable fallback — PASS.** Turning the Settings toggle off while `layoutMode == .wysiwyg` changed the
  layout to `sourceOnly`, changed labels to `Show Preview` / `Preview`, logged the deterministic fallback,
  and preserved the raw Markdown fixture exactly:

```markdown
# Heading

This is **bold**, *italic*, ~~strike~~, and `code`.

- item
> quote

[link](https://example.com)
```

### Regression posture

- Source-only and source+preview remain stable: the disabled cycle never enters WYSIWYG, and source modes
  do not pass `_developmentPresentation: .inlineFoldReveal`.
- Copy remains exact raw Markdown by policy and automated regression coverage
  (`WYSIWYGNativeInteractionGateTests.testPartialFoldedSpanCopyPolicyUsesExactRawSelection`,
  `...testNativeShiftSelectionAcrossFoldedBoldStrikeAndInlineCodeCopiesRawMarkdown`,
  `WYSIWYGNativePointerGateTests.testPointerDragSelectionAcrossFoldedSpansKeepsRawRangeAndCopy`). A manual
  clipboard attempt during this sign-off was discarded because focus moved to another app; it is not
  counted as evidence.
- Construct scope is unchanged: headings, emphasis/strong, strike, inline code, and list/quote marker
  styling only. Link visual folding, images, fenced-code custom fragments, tables, Mermaid/math widgets,
  and real MDX rendering remain deferred.

Stable/default promotion remains blocked by `docs/wysiwyg-release-checklist.md`: the promotion checkbox is
still unchecked and requires a Decision Log entry before WYSIWYG can become stable or on by default.
