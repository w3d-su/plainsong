# M5 Stabilization Plan & Dependency Order

> Living plan for M5 (MDX + polish, `agent.md` §14). M5 is too large for one PR, so it is split
> into PR-sized slices and follow-up gates. Status snapshot: **2026-06-24**.

## Current snapshot

M5 feature slices, performance gates, security hardening, and Settings/themes are in place. M5 is
**not complete** until the manual checklist passes and the final stale-doc/status sweep lands.

| Item | Content | Status | Notes |
|---|---|---|---|
| Slice 1 — MDX preview | `remark-mdx`, non-executed placeholders, stale/error preview liveness | ✅ Merged PR #8 | Feature accepted; sanitizer hardening landed in PR #24 |
| Planning docs | M5 checklist, perf log, slice plan, WYSIWYG design draft | ✅ Merged PR #9 | `docs/wysiwyg-design.md` remains draft / not approved |
| Slice 2 — TSX highlighting | Vendored TSX grammar and MDX ESM/JSX injection highlighting | ✅ Merged PR #10 | Known multiline JSX limitation remains acceptable for M5 |
| Slice 4 — App icon/accent | App icon, accent color, deterministic generator | ✅ Merged PR #11 | First-pass art; final brand sign-off remains subjective |
| Slice 5 — Performance pass | Fixtures, PerformanceTests target, perf log, preview update optimization | ✅ Merged PR #15 | Infrastructure only; follow-up gates tracked below |
| Settings + themes | Settings panes and live editor/preview theme preferences from `agent.md` §11 | ✅ This PR | Implements issue #16 scope; custom JSON/user CSS are deferred by Decision Log |
| Security hardening | MDX sanitizer tightening, asset size/type guards, large image copy behavior | ✅ Merged PR #24 + PR #27 follow-up; issue #17 closed | No inline `style`, script-like elements dropped before sanitize, raster assets only up to 10 MiB, SVG/path rejected |
| Hidden perf gate — highlight | Visible-range highlight update <50 ms | ✅ Merged PR #20; issue #14 closed | Measured Markdown 17.918 ms max and MDX 22.670 ms max; not based on the 250 KB cutoff |
| Hidden perf gate — memory | 8 warm sessions + 2 live webviews <400 MB host-process RSS | ✅ Merged PR #21 via PR #20; issue #13 closed after PR #22 scope cleanup | Measured 149.8 MB host RSS with 2 settled live webviews; WebKit helper memory remains diagnostic |

## Recommended next sequence

```text
0. PR #15, PR #20, PR #21, PR #22, PR #24, and PR #27 have merged; issues #13, #14, #17, and #18 are closed.
1. Merge the focused #16 Settings/themes PR or resolve its review feedback without expanding into Phase 2.
2. Run `docs/m5-checklist.md`.
3. Update README, `agent.md`, `docs/perf-log.md`, and this plan to the final M5 state.
4. Only then approve `docs/wysiwyg-design.md` and start Phase 2 design spikes. Do not start Phase 2 implementation before M5 exits.
```

The ordering above is intentionally conservative. `agent.md` §13 says Phase 2 begins only when M1–M5 are
complete and a WYSIWYG design doc is approved; the current repository is not there yet.

## Conflict hotspots

| File / area | Touched by | Handling |
|---|---|---|
| `project.yml` | PR #15 PerformanceTests, future test targets | Edit manifest only; run `make generate`; never commit hand-edited `.xcodeproj` |
| `docs/perf-log.md` | PR #15, #20, #21, future final M5 state update | Keep host RSS and WebKit helper diagnostics explicit |
| `preview-src/src/pipeline.ts` / `preview-src/src/index.ts` | MDX sanitizer hardening, theme/remote image work | Keep sanitizer and remote-image policy tests with any preview change |
| `preview-src/src/index.ts` | Preview render caching, theme bridge, scroll sync | Require `npm run typecheck`, `npm test`, and regenerated dist when changed |
| `MarkdownEditorView` / `MarkdownTextView` | Visible-range highlighting, IME safety, future WYSIWYG | Do not start WYSIWYG folding until M5 exits are complete |
| `agent.md` | Decision Log and milestone status | Update in the same PR when behavior or dependency policy changes |

## Risk notes

- **PR #15 must not be treated as full M5 completion.** It landed performance infrastructure while
  follow-up gates remained tracked separately.
- **Visible-range highlighting has landed, but remains a regression risk.** PR #20 measured the gate
  with visible-range-first parsing/apply; Phase 2 folding should still wait for the remaining M5 exits.
- **The two-webview memory gate uses a test-only harness.** Phase 1 has shared app-scoped state, so this
  PR #21 measured two live `PreviewController` WebViews attached to an offscreen AppKit surface. The
  accepted M5 gate is host-process RSS; WebKit helper memory remains diagnostic.
- **Settings + themes are implemented for the #16 scope, but manual validation remains.** Custom editor-theme
  JSON and user CSS overrides are deferred by Decision Log until separate import/sanitizer designs exist.
- **Security hardening has landed, but remains a regression risk.** MDX preview intentionally does not execute
  components; keep sanitizer and asset policy tests with any preview-src, PreviewKit, or WorkspaceKit change.

## Codex dispatch map

Use `docs/codex-handoff.md` as the copy/paste source for Codex prompts.

| Goal | Branch suggestion | Output |
|---|---|---|
| M5 manual checklist | `m5-final-checklist-docs` | Runs `docs/m5-checklist.md` and records any final evidence/status changes |
| Phase 2 design gate | `phase2-wysiwyg-design-gate` | Approves/refines design and spikes only after M5 exits |

## Beyond M5

There is no accepted "M6" in `agent.md`. After M5, the roadmap is Phase 2 WYSIWYG, then unscheduled Phase 3
candidates. Recommended order after M5:

1. Approve `docs/wysiwyg-design.md`.
2. Run Phase 2 spikes for IME, undo, selection, and delimiter folding.
3. Ship inline-only WYSIWYG first: headings, emphasis, inline code, links, task checkbox.
4. Defer images, tables, Mermaid, and embedded block widgets until the inline engine is proven.
5. Keep two-pane source + preview mode permanently available.
