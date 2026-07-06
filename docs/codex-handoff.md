# Codex Handoff — Phase 2 WYSIWYG Gate

Status snapshot: 2026-06-27.

This document turns the current roadmap into Codex-ready work packages. It is intentionally
operational: each section can be copied into Codex as a single goal, or split into subagents when the
work crosses EditorKit, MarkdownCore, PreviewKit, and app-level mode handling.

## Current state

- `main` has M0–M5 accepted.
- M5 acceptance is complete after PR #33:
  - PR #32 supplied broken-MDX edit/recovery evidence and MarkdownCore fenced-code component-completion suppression.
  - PR #33 supplied final live STTextView MDX completion-popup evidence in tag context and fenced-code context.
- PR #36 completed the Phase 2 Spike A/B/C/D evidence and recorded a GO recommendation for a narrow
  production-core PR.
- PR #38 completed issue #37 by merging the production inline fold/reveal core behind
  `MarkdownEditorView(..., _developmentPresentation: .inlineFoldReveal)`.
- PR #41 completed native selection/copy/paste/accessibility evidence for the production development
  hook, but left actual macOS IME event streams incomplete.
- The actual Zhuyin follow-up gate passed through the production development hook at heading, bold,
  italic, and inline-code boundaries.
- The actual Pinyin follow-up gate now also passes through the same hook (PR #43,
  `phase2-actual-pinyin-ime-gate`), using the enabled `com.apple.inputmethod.TCIM.Pinyin`
  (`Pinyin – Traditional`) input method. IME is no longer a Phase 2 blocker.
- The native pointer hit-testing / selection-edge gate now passes (PR for
  `phase2-native-pointer-selection-gate`): real `NSEvent` mouse-downs at the laid-out position of folded
  heading/bold/strike/inline-code delimiters place a sane caret, reveal the touched span, copy exact raw
  Markdown across a pointer-extended (drag) selection, and never trap the caret in a hidden delimiter.
- All native interaction gates for the attribute-only hook are now complete: IME (Zhuyin + Pinyin),
  keyboard selection/copy/paste/accessibility, and pointer/selection-edge.
- The App now passes that development hook only through the off-by-default Experimental WYSIWYG mode;
  with the flag disabled, `⌘⇧P` remains source+preview/source-only only.
- The user-facing WYSIWYG release checklist is now written: see `docs/wysiwyg-release-checklist.md`
  (Goal 5, branch `phase2-wysiwyg-release-checklist`). It remains blocking — WYSIWYG stays behind the
  development hook until every checkbox is green with linked evidence.
- Goal 6 replaced the `baselineOffset(-1000)` zero-width fold mechanism with a TextKit 2
  content-storage paragraph projection behind the non-user-facing hook and reran B1-B13 green. R18 is
  closed by the new B13 layout-geometry gate.
- Goal 7 landed delimiter edge-snapping (§C.2-§C.4) behind the dev hook on branch
  `phase2-wysiwyg-edge-snapping`: a collapsed caret that would rest inside a folded delimiter snaps to
  the delimiter-inner boundary (`WYSIWYGCaretSnap`) for keyboard movement and non-shift pointer clicks,
  while selections still span raw delimiter offsets so copy stays exact raw Markdown.
  `WYSIWYGEdgeSnappingGateTests` covers it; checklist §C.2-§C.4 are green.
- Goal 8 landed the **§D mode integration** on branch `phase2-wysiwyg-mode-integration`: the App has a
  three-state `EditorLayoutMode`, migration from `Plainsong.preview.isVisible`, an off-by-default
  Experimental `UserDefaults` kill switch, deterministic `.sourceOnly` recovery, and hook wiring that
  passes `_developmentPresentation: .inlineFoldReveal` only when the flag is enabled, the mode is
  WYSIWYG, and the mechanism has not failed. Link visual folding and deferred constructs remain out of
  scope.
- Goal 9 finishes the Experimental sign-off on branch `phase2-wysiwyg-experimental-signoff`: manual UI
  validation confirms the Settings label/default, disabled two-state cycle, enabled three-state cycle,
  View menu/toolbar labels, WYSIWYG inline fold/reveal, and disable-from-WYSIWYG fallback without source
  text changes. Issue #40 is complete across PR #41-#49. Native input/selection gates are no longer
  active blockers; stable/default promotion remains blocked by `docs/wysiwyg-release-checklist.md`.

## Rules for every Codex run

1. Read `agent.md` and `docs/wysiwyg-design.md` before editing.
2. One milestone-task per branch/PR. Phase 2 branches should use `phase2-<slug>`.
3. Never edit or commit `.xcodeproj`; edit `project.yml` and run `make generate` when target membership changes.
4. No new dependencies unless the PR adds a Decision Log entry with alternatives considered.
5. Logic changes need tests. Editor presentation changes must preserve source-only and source+preview behavior.
6. Do not mutate source text for WYSIWYG presentation. Folding/reveal is attributes/layout only.
7. IME marked-text correctness is non-negotiable. If a spike cannot keep Zhuyin/Pinyin safe, stop and report the blocker.
8. Run relevant verification before declaring done: `make format`, `make test`, and `git diff --check`; if preview-src changes, also run `cd preview-src && npm run typecheck && npm test`.

---

# Completed reference — M5 accepted

- PR #15/#20/#21/#22 landed performance infrastructure and hard gates.
- PR #24/#27 landed security hardening and SVG rejection.
- PR #26 landed Settings/themes and remote image policy.
- PR #29/#30 completed most M5 manual checklist work and fixed scroll sync, launch stability, and Open Recent behavior.
- PR #32 landed broken-MDX edit/recovery evidence and fenced-code completion suppression.
- PR #33 accepted M5 with final live MDX completion-popup evidence.

# Goal 0 — Phase 2 Spike A/B/C/D — completed by PR #36

```text
You are working in w3d-su/plainsong.

Goal: run Phase 2 WYSIWYG Spike A/B/C to prove fold/reveal safety before production implementation.

Branch:
- Create branch: phase2-wysiwyg-spikes
- One spike PR or a small stack of spike PRs is acceptable.
- Do not ship production WYSIWYG UI in this PR.
- Do not add the WYSIWYG mode to the user-facing ⌘⇧P cycle yet.

Read first:
- agent.md §13 and §17
- docs/wysiwyg-design.md
- Packages/EditorKit/Sources/EditorKit/MarkdownEditorView.swift
- Packages/EditorKit/Sources/EditorKit/MarkdownTextView.swift
- Packages/EditorKit/Sources/EditorKit/MarkdownTextViewCoordinator.swift
- Packages/EditorKit/Sources/EditorKit/MarkdownSyntaxParser.swift
- Packages/EditorKit/Tests/EditorKitTests

Use subagents if available:
1. Fold/reveal range-model subagent:
   - Build a prototype range model for headings, emphasis/strike, inline code, and links.
   - Keep it pure and testable; no source text mutation.
2. IME subagent:
   - Drive Traditional Chinese Zhuyin and Pinyin marked text through fold/reveal boundaries.
   - Confirm no corruption, no caret jumps, no premature commit.
3. Undo subagent:
   - Confirm folding/reveal state does not enter undo and recomputes after undo/redo.
4. Selection/copy subagent:
   - Confirm arrow keys, shift-selection, mouse selection, and copy map to raw Markdown source correctly.

Acceptance:
- Spike A: IME marked text remains correct at fold/reveal boundaries.
- Spike B: undo/redo restores source text + selection and never stores stale folded state.
- Spike C: selection/copy across folded bold/link ranges maps correctly to raw source.
- If all pass, update docs/wysiwyg-design.md with the go/no-go recommendation for production WYSIWYG v1.
- If any fail, do not proceed to implementation; document the blocker and safer fallback.

Verification:
- make format
- make test
- git diff --check
- Add targeted EditorKit tests for any reusable spike logic.
```

# Goal 1 — Production inline fold/reveal core — completed by PR #38

```text
Goal: implement the Phase 2 inline fold/reveal core behind non-user-facing development plumbing.

Initial construct scope:
- headings
- emphasis / strike
- inline code
- lists / quotes
- links, only if selection mapping passed Spike C

Deferred:
- image thumbnails
- fenced-code custom fragments
- tables
- Mermaid / math widgets
- real MDX component rendering

Hard gates:
- source-only and source+preview modes unchanged
- IME correctness
- undo/redo correctness
- selection/copy correctness
- visible-range performance within §12 budgets
```

PR #38 result:
- Production folding is attribute-only and visible-range bounded.
- Included constructs are headings, emphasis/strong, strikethrough, inline code, and list/quote marker
  styling only.
- Link visual folding remains deferred, although link ranges stay in the pure model for mapping tests.
- Automated `setMarkedText`, undo, selection/copy, and performance gates passed against the production
  hook.
- User-facing WYSIWYG remains blocked.

# Goal 2 — Phase 2 native interaction gates — completed by PR #41-#44 follow-ups

```text
Goal: prove native interaction safety for the PR #38 inline fold/reveal production core.

Branch:
- phase2-native-input-selection-gates
- One focused PR against main.
- Do not expose WYSIWYG in the user-facing Command-Shift-P cycle.
- Do not expand construct scope beyond the PR #38 development hook.

Gate scope:
- Actual macOS Zhuyin and Pinyin event streams at heading, bold/italic, and inline-code boundaries.
- Native arrow movement, reverse shift-selection, and mouse/click-to-caret near folded delimiters.
- Selection across folded bold, strike, and inline code.
- Copy policy for entire folded spans, visible content only, and selections beginning/ending at fold
  boundaries.
- Paste into folded/revealed regions must mutate source normally and never create presentation-only text.

Acceptance:
- If all native gates pass, recommend the next narrow PR.
- If any native gate fails or remains unproven, keep user-facing WYSIWYG blocked and document the exact
  fallback.
```

PR #41 historical result:
- Native arrow movement, reverse shift-selection, raw boundary selections, copy/paste policy, and
  accessibility evidence passed against the production development hook.
- Actual macOS IME event streams were still incomplete at this point; Goal 3 superseded that blocker.

Actual Zhuyin follow-up result:
- `WYSIWYGActualIMEEventGateTests/testActualZhuyinEventStreamAtFoldBoundaries` is an opt-in harness:
  run `PLAINSONG_RUN_ACTUAL_IME=1 swift test --filter WYSIWYGActualIMEEventGateTests/testActualZhuyinEventStreamAtFoldBoundaries`
  from `Packages/EditorKit`.
- The harness uses enabled TIS source `com.apple.inputmethod.TCIM.Zhuyin`, physical-key
  `CGEvent.postToPid` events, and the production `MarkdownSTTextView`/inline fold reveal path.
- Zhuyin passed at heading, bold, italic, and inline-code fold boundaries with no source corruption, no
  caret escape from marked text, no premature commit, fold attributes skipped during active marked text,
  and presentation reapply after commit.
- A production guard now reserves space, Return, and keypad Enter for the input context while marked text
  is active, preventing TCIM candidate/commit keys from also inserting ordinary whitespace/newlines.
- Historical PR #41 state: Pinyin was blocked on this machine because TIS saw Pinyin input methods as
  installed but not enabled/selectable and direct selection returned `-50`. Goal 3 superseded this; Pinyin
  is no longer an active blocker.

# Goal 3 — Actual Pinyin event-stream gate — completed by phase2-actual-pinyin-ime-gate

```text
Goal: enable a macOS Pinyin input method and rerun the actual IME harness.

Manual setup:
- System Settings > Keyboard > Text Input > Edit > + > Chinese.
- Enable Pinyin - Simplified or Pinyin - Traditional.

Verification:
- cd Packages/EditorKit
- PLAINSONG_RUN_ACTUAL_IME=1 swift test --filter WYSIWYGActualIMEEventGateTests/testActualPinyinEventStreamAtFoldBoundariesWhenEnabled

Acceptance:
- If Pinyin passes, recommend the next narrow pointer hit-testing/selection-edge PR.
- If Pinyin fails, keep WYSIWYG blocked and document the exact source/caret/commit failure.
```

Result:
- Pinyin was installed but not enabled on the machine (reproducing PR #42: TIS enabled lookup found none
  and direct `TISSelectInputSource` returned `-50`). Enabling it with
  `TISEnableInputSource(com.apple.inputmethod.TCIM.Pinyin)` returned `0`, after which the source selected.
- The harness selected enabled `com.apple.inputmethod.TCIM.Pinyin` (`Pinyin – Traditional`,
  `TISTypeKeyboardInputMode`). A robustness fix makes `ActualIMEInputSource.enabled(matching:)` pick only
  composition-capable input methods, never the same-named `com.apple.keylayout.PinyinKeyboard` /
  `TraditionalPinyinKeyboard` layouts that produce no marked text. Zhuyin was re-verified passing.
- `PLAINSONG_RUN_ACTUAL_IME=1 swift test --filter WYSIWYGActualIMEEventGateTests/testActualPinyinEventStreamAtFoldBoundariesWhenEnabled`
  passed at every fold boundary (heading; bold/italic/inline-code before and after both delimiters):
  no source corruption, no caret escape from the marked range, no premature commit, fold attributes
  skipped during marked text and never over the marked range, and presentation reapplied after commit.
  Toneless "tai" + space commits `太`; the Pinyin fixture now accepts 太/台/臺.
- Cold-start caveat: the first run after enabling the IME may produce no composition (TCIM server not yet
  warm; `error messaging the mach port for IMKCFRunLoopWakeUpReliable`). Re-run once; warm runs are
  deterministic.
- User-facing WYSIWYG remains blocked. See `docs/wysiwyg-design.md` §13.

# Goal 4 — Native pointer hit-testing / selection-edge gate — completed by phase2-native-pointer-selection-gate

```text
Goal: prove native pointer interaction safety for the PR #38 inline fold/reveal production core.

Branch:
- phase2-native-pointer-selection-gate
- One focused PR against main.
- Do not expose WYSIWYG in the user-facing Command-Shift-P cycle.
- Do not add a persisted WYSIWYG layout mode.
- Do not expand construct scope beyond the #38 development hook.
- Do not enable link visual folding.

Gate scope:
- True mouse hit-test / click-to-caret against the laid-out editor near hidden fold delimiters.
- Drag selection across folded bold, strike, and inline-code spans.
- Confirm raw source offsets, reveal-on-touch recompute, and exact raw-selection copy still hold under
  real pointer events (not just programmatic boundary selections).

Acceptance:
- If the pointer gates pass, the next PR can specify the user-facing WYSIWYG release checklist.
- If any pointer gate fails, keep user-facing WYSIWYG blocked and document the exact fallback.
```

Result:
- `WYSIWYGNativePointerGateTests` lays the production hook out in a real `NSWindow`, folds inline
  delimiters to ~zero width, and dispatches real `NSEvent` left-mouse-downs at the on-screen position of
  folded content (target from `firstRect(forCharacterRange:)`, caret from STTextView's own
  `mouseDown → caretLocation` hit-test).
- PASS: heading-marker, bold/strike/inline-code content, and delimiter-edge boundary clicks place a sane
  caret, reveal the touched span, and never trap the caret inside a hidden delimiter; clicks on trailing
  text keep spans folded. Pointer-extend (shift-click) drag selection across folded bold→strike→code
  copies exact raw Markdown (delimiters included) and reveals every touched span.
- Edge policy: reveal-on-touch is sufficient for the attribute-only hook; no delimiter edge-snapping is
  needed at this layer. Edge snapping is a UX refinement for the user-facing PR.
- Mechanism caveat (R18): the `baselineOffset(-1000)` zero-width fold makes a single folded line ~1013 pt
  tall, distorting multi-line viewport (an exhaustive every-glyph sweep was abandoned for this reason). It
  does not trap the caret. A user-facing WYSIWYG must adopt a cleaner zero-width mechanism and rerun the
  gates. See `docs/wysiwyg-design.md` §14.
- User-facing WYSIWYG remains blocked.

# Goal 5 — User-facing WYSIWYG release checklist — completed by phase2-wysiwyg-release-checklist

```text
Goal: specify (do not yet ship) the user-facing WYSIWYG release checklist.

Branch:
- phase2-wysiwyg-release-checklist
- One focused PR against main. Documentation/spec only unless a Decision Log entry justifies code.
- Still do not expose WYSIWYG in Command-Shift-P or persist a WYSIWYG layout mode in this PR.

Checklist must define:
- A cleaner zero-width fold mechanism (NSTextLayoutFragment customization or attachment hiding) to replace
  baselineOffset(-1000), with the gate-rerun matrix (IME Zhuyin/Pinyin, keyboard + pointer selection/copy,
  accessibility, performance) against that mechanism (R18).
- Delimiter edge-snapping UX for caret/selection near hidden delimiters.
- The ⌘⇧P cycle entry (source+preview → source-only → WYSIWYG) and persisted layout mode.
- Link visual folding only after its own native selection/copy coverage exists.
- Construct scope stays headings/emphasis/strike/inline-code/list-quote; images/fences/tables/
  Mermaid/math/MDX rendering stay deferred.

Acceptance:
- A reviewed checklist doc with explicit, testable gates. WYSIWYG stays blocked until each is green.
```

Result:
- `docs/wysiwyg-release-checklist.md` is the blocking checklist. It is grouped A (mechanism), B (gate-rerun
  matrix), C (UX policy), D (mode integration), E (scope), F (final sign-off), and every item is a `- [ ]`
  release gate requiring linked evidence.
- Mechanism decision: primary = `NSTextLayoutFragment` customization (TextKit 2-native, keeps the backing
  string canonical); fallback = attachment-based hiding, only if it proves exact-raw copy and raw
  accessibility value; tiny-font/kern, TextKit 1 glyph suppression, and text deletion rejected. Recorded in
  the `agent.md` Decision Log.
- The §B matrix requires every existing native gate (IME Zhuyin/Pinyin, keyboard arrow/shift-selection,
  pointer click/drag, copy, paste, accessibility, large-doc performance, undo/redo, source-only/source+
  preview regression) to rerun against the §A mechanism, plus a new layout-geometry sanity gate (B13) that
  closes R18.
- UX policy: reveal-on-touch retained; edge-snapping required for user-facing mode; selection may still span
  raw delimiter offsets; copy stays exact raw Markdown; link visual folding deferred behind its own sub-gate.
- Mode integration: three-state `⌘⇧P` cycle, three-state persisted enum with migration from
  `Plainsong.preview.isVisible`, kill switch + deterministic fallback to source-only, off-by-default
  Experimental label until the checklist is fully green.
- This PR exposes no user-facing WYSIWYG, persists no WYSIWYG layout mode, adds no link folding, and changes
  no construct scope.

# Goal 6 — Cleaner zero-width fold mechanism prototype — completed by phase2-wysiwyg-zerowidth-mechanism

```text
Goal: replace the baselineOffset(-1000) zero-width fold mechanism (R18) and rerun the gate matrix.
This is NOT the user-facing mode PR.

Branch:
- phase2-wysiwyg-zerowidth-mechanism (suggested)
- One focused PR against main.
- Keep WYSIWYG behind _developmentPresentation: .inlineFoldReveal. Do not expose it in Command-Shift-P
  and do not persist a WYSIWYG layout mode.
- Do not enable link visual folding. Do not expand construct scope.

Read first:
- docs/wysiwyg-release-checklist.md (especially §A and §B)
- docs/risk-register.md R18
- Packages/EditorKit/Sources/EditorKit/WYSIWYGInlineFoldPresentation.swift
- Packages/EditorKit/Sources/EditorKit/MarkdownTextView.swift
- Packages/EditorKit/Tests/EditorKitTests/WYSIWYGNativePointerGateTests.swift

Implement:
- Primary: NSTextLayoutFragment customization (via NSTextLayoutManagerDelegate) that lays the delimiter
  run out at zero advance and skips drawing it, without mutating the backing string. Confirm STTextView
  lets us own/chain the layout-fragment delegate.
- Fallback (only if STTextView cannot host the custom fragment): zero-size NSTextAttachment hiding, with
  explicit proof that copy and AXValue remain exact raw Markdown (no U+FFFC leakage).
- Remove or demote baselineOffset(-1000) + 0.1pt clear-font hiding once the replacement lands.

Acceptance (checklist §A + §B):
- A.3 invariants proven (source canonicality, geometry sanity, source-only/source+preview unchanged,
  attribute compatibility, no undo pollution).
- New layout-geometry test (B13): folded-line fragment height ≈ unfolded-line height; multi-line fold does
  not displace the viewport.
- Rerun B1–B12 against the new mechanism (IME harness opt-in). Record large-doc perf in docs/perf-log.md.
- Record the chosen mechanism in the agent.md Decision Log; update R18 (close only when A + B13 are green).

Verification:
- make format
- make test
- git diff --check
- PLAINSONG_RUN_ACTUAL_IME=1 swift test --filter WYSIWYGActualIMEEventGateTests (from Packages/EditorKit)
```

Result:
- Implemented a TextKit 2 `NSTextContentStorageDelegate` paragraph projection behind
  `_developmentPresentation: .inlineFoldReveal`: folded delimiter attributes project to equal-length
  U+200B runs for layout while `NSTextStorage.string` remains exact raw Markdown.
- The `NSTextLayoutFragment` delegate path was attempted but not used because STTextView 2.3.10 owns the
  layout-fragment delegate (`STTextLayoutFragment`) and the custom line-fragment prototype did not safely
  drive native `firstRect` / pointer hit-testing.
- Removed the old `baselineOffset(-1000)` + 0.1 pt clear-font hiding from `WYSIWYGInlineFoldPresentation`.
  No attachment fallback was used, no U+FFFC is introduced, and no TextKit 1 path was added.
- Added B13:
  `WYSIWYGNativePointerGateTests.testFoldedLineGeometryMatchesUnfoldedLineAndKeepsSiblingLinesInViewport`.
- Reran B1-B13 green, including the opt-in actual Zhuyin/Pinyin IME harness, and recorded WYSIWYG
  visible-range fold/highlight/apply at 26.964 ms in `docs/perf-log.md`.
- R18 is closed. User-facing WYSIWYG still remains blocked: no `⌘⇧P` exposure, no persisted WYSIWYG layout
  mode, no link visual folding, and no deferred constructs were added.

# Goal 7 — Delimiter edge-snapping — completed by phase2-wysiwyg-edge-snapping

```text
Goal: implement Phase 2 WYSIWYG delimiter edge-snapping UX behind the non-user-facing dev hook.

Branch:
- phase2-wysiwyg-edge-snapping
- One focused PR against main. No ⌘⇧P exposure, no persisted WYSIWYG layout mode, no link folding,
  no new constructs.
```

Result:
- Added `WYSIWYGCaretSnap.snap(offset:foldedDelimiterRanges:preferring:)` (pure) plus
  `MarkdownSTTextView.wysiwygFoldedDelimiterRange(containingInterior:)` /
  `wysiwygSnappedCaretOffset(_:preferring:)`, which read the live `foldedDelimiterAttribute` runs from
  the backing text storage with a bounded `longestEffectiveRange` scan.
- Collapsed-caret keyboard movement (`moveLeft`/`moveRight` via
  `applyWYSIWYGComposedCharacterMovement`) and non-shift `mouseDown` now snap a destination that lands
  strictly inside a folded delimiter to the delimiter-inner boundary. The extending keyboard branch and
  the shift `mouseDown` (pointer-extend/drag) branch are untouched, so selections still span raw
  delimiter offsets and copy stays exact raw Markdown. Source text is never mutated.
- Tests: `WYSIWYGEdgeSnappingGateTests` (pure function, keyboard bold/strike/heading snap + inline-code
  no-trap, pointer snap-from-storage + real-click no-trap, shift-selection raw copy, emoji/CJK movement).
  Repurposed `WYSIWYGNativeInteractionGateTests.testNativeArrowIntoFoldedDelimiterSnapsToInnerEdgeAndReveals`
  (was `...LandingInsideFoldedDelimiterRevealsInsteadOfTrapping`, B3). Existing native-interaction and
  pointer gates stay green; large-doc WYSIWYG fold/highlight/apply stayed at 25.348 ms.
- Checklist §C.2-§C.4 are green; §C.1 reveal-timing and §C.5 link-deferral confirmation land with §D.
  User-facing WYSIWYG remains blocked: no `⌘⇧P` exposure, no persisted WYSIWYG layout mode, no link
  visual folding, no construct-scope change.

# Goal 8 — WYSIWYG mode integration — completed by phase2-wysiwyg-mode-integration

```text
Goal: implement the §D user-facing WYSIWYG mode-integration gates after edge-snapping passed.

Branch:
- phase2-wysiwyg-mode-integration (suggested)
- One focused PR against main, or split if review scope grows.

Read first:
- docs/wysiwyg-release-checklist.md §D/§F
- docs/wysiwyg-design.md §16/§17
- docs/risk-register.md R12/R17/R18
- agent.md Decision Log entries dated 2026-06-26 / 2026-06-27
- App/AppState.swift
- Packages/EditorKit/Sources/EditorKit/MarkdownEditorView.swift
- Packages/EditorKit/Sources/EditorKit/MarkdownSTTextView.swift

Implement:
- A reviewed three-state `⌘⇧P` cycle (source+preview → source-only → WYSIWYG), persisted layout enum and
  migration from the `Plainsong.preview.isVisible` boolean, kill switch / deterministic `.sourceOnly`
  recovery, and an off-by-default Experimental label.
- Wire the App to pass `_developmentPresentation: .inlineFoldReveal` only when the experimental flag is
  on; keep WYSIWYG off by default until all release gates are green.

Do not:
- Enable link visual folding.
- Add images, fenced-code custom fragments, tables, Mermaid/math widgets, or real MDX rendering.
- Change copy policy away from exact raw Markdown.

Verification:
- make format
- make test
- git diff --check
- PLAINSONG_RUN_ACTUAL_IME=1 swift test --filter WYSIWYGActualIMEEventGateTests (from Packages/EditorKit)
- Add targeted mode-persistence/migration and recovery tests.
```

Outcome:
- Added `EditorLayoutMode.sourcePreview/sourceOnly/wysiwyg` and migrated the legacy
  `Plainsong.preview.isVisible` key into `Plainsong.layout.mode`.
- Added the off-by-default `Plainsong.settings.experimentalWYSIWYGEnabled` Settings toggle labeled
  **WYSIWYG mode (Experimental)**.
- Kept `⌘⇧P` to source+preview ↔ source-only while disabled; when enabled and healthy it cycles
  source+preview → source-only → WYSIWYG → source+preview.
- Added deterministic fallback to source-only for disabled persisted WYSIWYG and mechanism failure,
  with AppState recovery state plus logging.
- Scope stayed unchanged: no link visual folding, no images/fences/tables/Mermaid/math widgets, no real
  MDX rendering, and source text remains canonical.

# Goal 9 — Experimental WYSIWYG sign-off and docs cleanup — completed by phase2-wysiwyg-experimental-signoff

```text
Goal: finish Phase 2 WYSIWYG Experimental sign-off and docs cleanup after PR #49.

Branch:
- phase2-wysiwyg-experimental-signoff
- One focused PR against main.
- Do not promote WYSIWYG to stable/default.
- Do not enable link visual folding.
- Do not add images, fenced-code custom fragments, tables, Mermaid/math widgets, or real MDX rendering.

Acceptance:
- Close/update issue #40 as completed by PR #41-#49.
- Manually verify Settings label/default, disabled and enabled layout cycles, View menu/toolbar labels,
  WYSIWYG inline fold/reveal, and disable-from-WYSIWYG fallback without source mutation.
- Mark only the verified checklist items in `docs/wysiwyg-release-checklist.md`; keep stable/default
  promotion unchecked.
- Keep README/design/risk/handoff docs synchronized with Experimental/off-by-default behavior.
- Run `make format`, `make test`, and `git diff --check`.
```

Result:
- Manual Debug app sign-off passed on 2026-06-27. With the flag off, `⌘⇧P` and toolbar/menu controls
  cycled only `sourcePreview <-> sourceOnly`. With the flag on, they cycled
  `sourcePreview -> sourceOnly -> wysiwyg -> sourcePreview` and labels reflected the current next mode.
- Settings > Editor showed `WYSIWYG mode (Experimental)` with value `0` by default.
- WYSIWYG showed the inline fold/reveal editor without a preview pane; the heading marker folded while the
  raw source still contained `# Heading`, and `[link](https://example.com)` remained raw, confirming link
  visual folding stayed off.
- Turning the Settings flag off while in WYSIWYG fell back to `sourceOnly`, changed labels to
  `Show Preview` / `Preview`, logged the deterministic fallback, and preserved the raw Markdown fixture.
- Stable/default promotion remains blocked by `docs/wysiwyg-release-checklist.md`; the promotion checkbox
  is intentionally still unchecked.


---

# Next goals — post-#51 follow-ups (2026-07-02)

Status update: PR #50 (Experimental sign-off) and PR #51 (dogfood polish: visible fallback
banner, Settings caption, toolbar tooltip) are merged. CI was offline 06-24 → 07-01 (June
Actions quota exhaustion; runner allocation failed with no runner assigned) and was
restored by the July billing reset plus PR #52 (SwiftFormat/SwiftLint drift + outage-window
lint debt). CI now runs on `pull_request` and `workflow_dispatch` only (Decision Log
2026-07-02).

## Goal 10 — WYSIWYG dogfood + D.4 stable-promotion evidence

Owner-driven, not Codex-driven: use Experimental WYSIWYG for real authoring sessions on
macOS. Collect fold/reveal annoyances, caret/IME surprises, and fallback-banner sightings
as issues. The D.4 promotion gate in `docs/wysiwyg-release-checklist.md` stays unchecked
until dogfood evidence plus a Decision Log entry justify promotion.

## Goal 11 — Link visual folding sub-gate

Spec: `docs/link-folding-gates.md` (L1-L9). One PR may implement fold/reveal + gates behind
the existing Experimental flag; enabling link folding requires all L-gates green and its own
Decision Log entry. Reference-style links, autolinks, and images stay raw/deferred.

## Goal 12 — Release engineering (R14)

Plan: `docs/release-engineering-plan.md`. P0 owner decisions (license — no LICENSE file
exists today — distribution, updates, crash/feedback, versioning) block P1-P5 pipeline work
(Developer ID signing, hardened runtime, notarization, DMG packaging, optional tag-triggered
release CI). R14 closes when the P5 alpha checklist passes on a clean macOS VM.


---

# Status snapshot — 2026-07-05 (post-launch)

- **v0.1.0-alpha.1 is publicly released** (`Plainsong-0.1.0-56-unsigned.dmg` + SHA-256 on
  GitHub Releases). The repo is **public under MIT**; secret scanning + push protection,
  Dependabot (graph/alerts/security updates, grouped), and a `main` branch ruleset
  (PR-only, `build-and-test` required, no bypass) are enabled.
- R14 closed (P5 fully checked); R15 broadened (all wall-clock perf budgets are
  CI-informational, hard locally); P4 unsigned release CI landed
  (`.github/workflows/release.yml`, tag/dispatch-only, draft prereleases).
- First Dependabot cycle handled: dompurify 3.4.9 → 3.4.11 (PR #63). **Pattern to keep:**
  Dependabot bumps touching `preview-src` must be superseded by a PR that also reruns
  `make preview-bundle`, because the preview ships as the committed dist bundle.
- Owner-driven next: WYSIWYG dogfood (Goal 10 / D.4 evidence), promotion, issue triage.
- Next scheduled feature: **Goal 11 — link visual folding**. A copy-paste agent prompt
  follows.

## Goal 11 — copy-paste prompt for the implementing agent

```text
You are working in w3d-su/plainsong (public repo).

Goal: implement link visual folding for the Experimental WYSIWYG mode, satisfying the
approved sub-gate spec docs/link-folding-gates.md (gates L1-L9).

Read first, in this order:
- agent.md — sections 13 and 17, plus the Decision Log entries dated 2026-06-26/27
- docs/link-folding-gates.md — the gate list this work must satisfy
- docs/wysiwyg-release-checklist.md — sections A and C (mechanism + UX policy)
- Packages/EditorKit/Sources/EditorKit/WYSIWYGFoldModel.swift
- Packages/EditorKit/Sources/EditorKit/WYSIWYGFoldParser.swift and WYSIWYGFoldParser+Inline.swift
- Packages/EditorKit/Sources/EditorKit/WYSIWYGInlineFoldPresentation.swift
- Packages/EditorKit/Sources/EditorKit/WYSIWYGZeroWidthTextContentProjection.swift
- Packages/EditorKit/Sources/EditorKit/MarkdownSTTextView.swift (WYSIWYGCaretSnap usage)
- Packages/EditorKit/Tests/EditorKitTests/WYSIWYG*GateTests.swift — mirror these test patterns

Branch and PR discipline:
- Branches named phase2-link-folding-<slug>; PRs against main; the maintainer squash-merges.
- Split into review-sized PRs:
  PR A: fold model + presentation for inline links [text](url) behind the existing
        Experimental/dev hook — fold the "[" and "](url)" chrome, keep the link text
        visible with link styling from the theme; L1 + L2 tests.
  PR B: destination-edge caret snapping (extend WYSIWYGCaretSnap for the asymmetric
        hidden-URL span), plus the L3/L4/L6/L7/L9 gates (keyboard, partial-URL raw copy,
        real-NSEvent pointer, accessibility, undo) and the L8 perf probe
        (visible-range fold recompute on Fixtures/large-1mb.md <= 50 ms, recorded in
        docs/perf-log.md; add a link-dense section to the fixture if needed).
  PR C: ONLY after the owner has run the opt-in actual-IME harness (L5,
        PLAINSONG_RUN_ACTUAL_IME=1, Zhuyin + Pinyin) on a real Mac: check the remaining
        gates in docs/link-folding-gates.md, add the Decision Log entry recording the
        L2 pointer policy, and turn on link folding (still inside the Experimental
        WYSIWYG mode only).

Hard rules (a violation rejects the PR regardless of features):
- Never mutate source text for presentation. Folding is attributes/layout only, through
  the existing NSTextContentStorage paragraph projection. No NSTextAttachment, no
  U+FFFC, no TextKit 1 code paths, no textLayoutManager.delegate takeover.
- Copy is exact raw Markdown for the selected NSRange (checklist C.4). Selections may
  span hidden-URL offsets and must never be clamped (C.3).
- Edge-snapping adjusts collapsed-caret rest only, never selection ranges (C.2).
- Reference links [text][ref], autolinks <https://…>, and images ![alt](src) stay raw.
- Plain click places the caret and reveals (Typora behavior, agent.md 17.12). Do not add
  cmd-click URL opening unless separately gated and documented.
- Fold attributes must be skipped while IME marked text exists. Do NOT claim L5 from
  synthetic setMarkedText tests — L5 requires the real-IME harness only the owner can
  run. Leave L5 unchecked and link folding disabled until then.
- agent.md section 17 layering is law. make format before committing. No new
  dependencies (Swift or npm).

Verification before declaring any PR done:
- make format && make test && git diff --check
- Update docs/link-folding-gates.md checkboxes only with named-test evidence.
- State in the PR body exactly which L-gates the PR closes and which remain open.
```
