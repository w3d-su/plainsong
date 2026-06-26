# M5 Stabilization Plan & Phase 2 Entry

> Historical plan for M5 (MDX + polish, `agent.md` §14) and the current Phase 2 entry
> sequence. Status snapshot: **2026-06-26**.

## Current snapshot

M5 is accepted. The final acceptance path was:

- PR #15, #20, #21, and #22 landed performance infrastructure and hard gates.
- PR #24 and PR #27 landed M5 security hardening and SVG policy alignment.
- PR #26 landed Settings/themes.
- PR #29 and PR #30 completed most manual checklist items and fixed scroll sync, launch stability,
  and Open Recent persistence behavior.
- PR #32 covered the broken-MDX edit/reintroduce recovery loop and MarkdownCore fenced-code
  component-completion suppression.
- PR #33 supplied the final live MDX completion-popup evidence and accepted M5.

This PR approves `docs/wysiwyg-design.md` for Phase 2 spikes only. It does **not** start production
WYSIWYG implementation.

| Item | Content | Status | Notes |
|---|---|---|---|
| Slice 1 — MDX preview | `remark-mdx`, non-executed placeholders, stale/error preview liveness | ✅ Merged PR #8 | Feature accepted; sanitizer hardening landed in PR #24 |
| Planning docs | M5 checklist, perf log, slice plan, WYSIWYG design | ✅ Merged PR #9 + this PR | WYSIWYG design gate is approved for spikes only |
| Slice 2 — TSX highlighting | Vendored TSX grammar and MDX ESM/JSX injection highlighting | ✅ Merged PR #10 | Known multiline JSX limitation remains acceptable for M5 |
| Slice 4 — App icon/accent | App icon, accent color, deterministic generator | ✅ Merged PR #11 | First-pass art; final brand sign-off remains subjective |
| Slice 5 — Performance pass | Fixtures, PerformanceTests target, perf log, preview update optimization | ✅ Merged PR #15 | Infrastructure plus follow-up gates accepted |
| Settings + themes | Settings panes and live editor/preview theme preferences from `agent.md` §11 | ✅ Merged PR #26; issue #16 closed | Custom JSON/user CSS are deferred by Decision Log |
| Security hardening | MDX sanitizer tightening, asset size/type guards, large image copy behavior | ✅ Merged PR #24 + PR #27 follow-up; issue #17 closed | No inline `style`, script-like elements dropped before sanitize, raster assets only up to 10 MiB, SVG/path rejected |
| Final editor-input acceptance | Broken-MDX edit/recovery, MDX completion popup tag-context pass, and fenced-code completion suppression | ✅ PR #32 + PR #33 | M5 accepted after PR #33 |
| Phase 2 design gate | WYSIWYG scope, open decisions, and spike plan | ✅ This PR | Spikes may begin; implementation remains blocked until spikes pass |

## Recommended next sequence

```text
0. M5 is accepted after PR #33.
1. Merge this Phase 2 design-gate PR.
2. Run Phase 2 Spike A/B/C only:
   - IME composition safety,
   - undo coordination,
   - selection/copy across folded tokens.
3. Record spike results and decide go/no-go for production WYSIWYG v1.
4. Do not start production WYSIWYG implementation until the spike results pass and are accepted.
```

## Conflict hotspots

| File / area | Touched by | Handling |
|---|---|---|
| `project.yml` | future spike/test targets | Edit manifest only; run `make generate`; never commit hand-edited `.xcodeproj` |
| `MarkdownEditorView` / `MarkdownTextView` | fold/reveal spikes, IME, undo, selection | Do not mutate source text for presentation; keep visible-range-first updates |
| `MarkdownTextViewCoordinator` | marked text, selection, completion, command routing | Preserve Phase 1 typing hot path and IME guards |
| `MarkdownSyntaxParser` / tree-sitter ranges | fold/reveal node range mapping | Keep parser work off-main and scoped to visible/dirty ranges |
| `docs/wysiwyg-design.md` | Phase 2 scope and spike gates | Update with actual spike results before implementation |
| `agent.md` | Decision Log and milestone status | Update in the same PR when architectural decisions change |

## Risk notes

- **IME correctness is the top Phase 2 gate.** Zhuyin/Pinyin marked text must not corrupt composition or jump the caret.
- **Undo must remain text-owned.** Folding/reveal attributes must not enter the undo stack.
- **Selection/copy mapping must stay source-accurate.** Copying folded content should yield raw Markdown.
- **Tables, Mermaid, math, images, and real MDX rendering stay deferred.** They should not block the inline-first core.
- **The PR #30 workspace shell uses `HStack` intentionally.** Restoring adjustable/native sidebar behavior is post-M5 polish, not Phase 2 WYSIWYG scope.
- **Public release hardening remains separate.** License, signing, hardened runtime, notarization, and release packaging are not solved by Phase 2.

## Codex dispatch map

Use `docs/codex-handoff.md` as the copy/paste source for Codex prompts.

| Goal | Branch suggestion | Output |
|---|---|---|
| Phase 2 spikes | `phase2-wysiwyg-spikes` | Spike A/B/C evidence and go/no-go recommendation |
| Phase 2 v1 implementation | blocked until spikes pass | Inline-first WYSIWYG production implementation |

## Beyond the design gate

After this design gate lands, the roadmap is:

1. Run Phase 2 spikes for IME, undo, and selection/copy.
2. If spikes pass, implement the inline-first fold/reveal model.
3. Ship headings, emphasis/strike, inline code, lists/quotes, and links first.
4. Defer images, fenced-code fragments, tables, Mermaid/math, and real MDX rendering until the core is proven.
5. Keep source-only and source+preview modes permanently available.
