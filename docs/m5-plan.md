# M5 Stabilization Plan & Dependency Order

> Living plan for M5 (MDX + polish, `agent.md` §14). M5 is too large for one PR, so it is split
> into PR-sized slices and follow-up gates. Status snapshot: **2026-06-25**.

## Current snapshot

M5 feature slices, performance gates, security hardening, Settings/themes, launch stability, and
Open Recent failure handling are in place. The `m5-editor-input-checklist` follow-up live-verified
the broken-MDX edit/reintroduce recovery loop and fixed fenced-code component completion suppression
in MarkdownCore. M5 is feature-complete but **not accepted** because `docs/m5-checklist.md` still
leaves live completion-popup checklist blockers.

| Item | Content | Status | Notes |
|---|---|---|---|
| Slice 1 — MDX preview | `remark-mdx`, non-executed placeholders, stale/error preview liveness | ✅ Merged PR #8 | Feature accepted; sanitizer hardening landed in PR #24 |
| Planning docs | M5 checklist, perf log, slice plan, WYSIWYG design draft | ✅ Merged PR #9 | `docs/wysiwyg-design.md` remains draft / not approved |
| Slice 2 — TSX highlighting | Vendored TSX grammar and MDX ESM/JSX injection highlighting | ✅ Merged PR #10 | Known multiline JSX limitation remains acceptable for M5 |
| Slice 4 — App icon/accent | App icon, accent color, deterministic generator | ✅ Merged PR #11 | First-pass art; final brand sign-off remains subjective |
| Slice 5 — Performance pass | Fixtures, PerformanceTests target, perf log, preview update optimization | ✅ Merged PR #15 | Infrastructure only; follow-up gates tracked below |
| Settings + themes | Settings panes and live editor/preview theme preferences from `agent.md` §11 | ✅ Merged PR #26; issue #16 closed | Custom JSON/user CSS are deferred by Decision Log |
| Security hardening | MDX sanitizer tightening, asset size/type guards, large image copy behavior | ✅ Merged PR #24 + PR #27 follow-up; issue #17 closed | No inline `style`, script-like elements dropped before sanitize, raster assets only up to 10 MiB, SVG/path rejected |
| Hidden perf gate — highlight | Visible-range highlight update <50 ms | ✅ Merged PR #20; issue #14 closed | Measured Markdown 17.918 ms max and MDX 22.670 ms max; not based on the 250 KB cutoff |
| Hidden perf gate — memory | 8 warm sessions + 2 live webviews <400 MB host-process RSS | ✅ Merged PR #21 via PR #20; issue #13 closed after PR #22 scope cleanup | Measured 149.8 MB host RSS with 2 settled live webviews; WebKit helper memory remains diagnostic |
| Final checklist blocker fixes | Workspace launch stability, Open Recent failure handling, and updated M5 checklist evidence | ✅ Merged PR #30 | Stable fixed-width `HStack` sidebar/detail shell accepted for M5; adjustable/native sidebar restoration is post-M5 polish |

Remaining unchecked M5 blockers are limited to live MDX completion-popup validation:

1. Type `<` in an `.mdx` tag context with imports and confirm the imported-component completion popup appears.
2. Confirm MDX component completion does not appear inside fenced code or obvious non-tag contexts.

## Recommended next sequence

```text
0. PR #15, PR #20, PR #21, PR #22, PR #24, PR #26, PR #27, PR #29, and PR #30 have merged; issues #13, #14, #16, #17, and #18 are closed.
1. Resolve only the remaining editor-input items in `docs/m5-checklist.md` without adding new M5 features.
2. If the checklist then passes, mark M5 accepted and move to Phase 2 WYSIWYG design approval/spikes only.
3. Do not start Phase 2 implementation before M5 is accepted and `docs/wysiwyg-design.md` is approved.
```

The ordering above is intentionally conservative. `agent.md` §13 says Phase 2 begins only when M1-M5 are
complete and a WYSIWYG design doc is approved; the current repository is not there yet because the
manual checklist is incomplete.

## Conflict hotspots

| File / area | Touched by | Handling |
|---|---|---|
| `project.yml` | PR #15 PerformanceTests, future test targets | Edit manifest only; run `make generate`; never commit hand-edited `.xcodeproj` |
| `docs/perf-log.md` | PR #15, #20, #21, future final M5 state update | Keep host RSS and WebKit helper diagnostics explicit |
| `preview-src/src/pipeline.ts` / `preview-src/src/index.ts` | MDX sanitizer hardening, theme/remote image work | Keep sanitizer and remote-image policy tests with any preview change |
| `preview-src/src/index.ts` | Preview render caching, theme bridge, scroll sync | Require `npm run typecheck`, `npm test`, and regenerated dist when changed |
| `MarkdownEditorView` / `MarkdownTextView` | Visible-range highlighting, IME safety, future WYSIWYG | Do not start WYSIWYG folding until M5 is accepted and the design gate is approved |
| `agent.md` | Decision Log and milestone status | Update in the same PR when behavior or dependency policy changes |

## Risk notes

- **PR #15 must not be treated as full M5 completion.** It landed performance infrastructure while
  follow-up gates remained tracked separately.
- **Visible-range highlighting has landed, but remains a regression risk.** PR #20 measured the gate
  with visible-range-first parsing/apply; Phase 2 folding should still wait for M5 acceptance.
- **The two-webview memory gate uses a test-only harness.** Phase 1 has shared app-scoped state, so this
  PR #21 measured two live `PreviewController` WebViews attached to an offscreen AppKit surface. The
  accepted M5 gate is host-process RSS; WebKit helper memory remains diagnostic.
- **Settings + themes are implemented for the #16 scope in PR #26 and manually checked in PR #30.** Keep
  them as regression-sensitive because they touch live editor/preview state; custom editor-theme JSON and
  user CSS overrides are deferred by Decision Log until separate import/sanitizer designs exist.
- **The PR #30 workspace shell uses `HStack` intentionally.** `NavigationSplitView` caused an AppKit
  constraint-loop crash during manual launch, so the fixed-width sidebar/detail `HStack` is the accepted
  M5 stability tradeoff. Restoring an adjustable/native sidebar is post-M5 polish, not part of PR #30.
- **Security hardening has landed, but remains a regression risk.** MDX preview intentionally does not execute
  components; keep sanitizer and asset policy tests with any preview-src, PreviewKit, or WorkspaceKit change.

## Codex dispatch map

Use `docs/codex-handoff.md` as the copy/paste source for Codex prompts.

| Goal | Branch suggestion | Output |
|---|---|---|
| M5 checklist blockers | `m5-editor-input-checklist` | Completes or documents the remaining live editor-input items in `docs/m5-checklist.md` |
| Phase 2 design gate | `phase2-wysiwyg-design-gate` | Approves/refines design and spikes only after M5 is accepted |

## Beyond M5

There is no accepted "M6" in `agent.md`. After M5 is accepted, the roadmap is Phase 2 WYSIWYG, then unscheduled Phase 3
candidates. Recommended order after M5 acceptance:

1. Approve `docs/wysiwyg-design.md`.
2. Run Phase 2 spikes for IME, undo, selection, and delimiter folding.
3. Ship inline-only WYSIWYG first: headings, emphasis, inline code, links, task checkbox.
4. Defer images, tables, Mermaid, and embedded block widgets until the inline engine is proven.
5. Keep two-pane source + preview mode permanently available.
