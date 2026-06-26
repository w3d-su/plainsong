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
- The App still does not pass or persist that development hook. The user-facing `⌘⇧P` cycle remains
  source+preview/source-only only.
- Next active goal: Phase 2 native interaction gates for the production fold/reveal core. Prove actual
  macOS IME streams, native selection/caret behavior, and copy/paste policy before any user-facing
  WYSIWYG mode is considered.

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

# Goal 2 — Phase 2 native interaction gates — active

```text
Goal: prove native interaction safety for the PR #38 inline fold/reveal production core.

Branch:
- phase2-native-interaction-gates
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
