# Codex Handoff — Phase 2 WYSIWYG Gate

Status snapshot: 2026-06-26.

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
- The actual Pinyin follow-up gate now also passes through the same hook (PR for
  `phase2-actual-pinyin-ime-gate`), using the enabled `com.apple.inputmethod.TCIM.Pinyin`
  (`Pinyin – Traditional`) input method. IME is no longer a Phase 2 blocker.
- The App still does not pass or persist that development hook. The user-facing `⌘⇧P` cycle remains
  source+preview/source-only only.
- Next active goal: add a narrow native pointer hit-testing / selection-edge gate against the production
  development hook before any user-facing WYSIWYG mode is considered.

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

# Goal 2 — Phase 2 native interaction gates — partially complete

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

PR #41 result:
- Native arrow movement, reverse shift-selection, raw boundary selections, copy/paste policy, and
  accessibility evidence passed against the production development hook.
- Actual macOS IME event streams were still incomplete.

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
- Pinyin remains blocked on this machine: TIS sees Pinyin input methods as installed, but none are
  enabled/selectable and direct selection returned `-50`. Keep user-facing WYSIWYG blocked.

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

# Goal 4 — Native pointer hit-testing / selection-edge gate — active

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
