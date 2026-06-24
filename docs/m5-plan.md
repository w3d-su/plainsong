# M5 Stabilization Plan & Dependency Order

> Living plan for M5 (MDX + polish, `agent.md` §14). M5 is too large for one PR, so it is split
> into PR-sized slices and follow-up gates. Status snapshot: **2026-06-24**.

## Current snapshot

M5 feature slices have mostly landed, and the performance gates are mostly measured. M5 is **not complete**
because Settings/themes and security hardening remain open, and issue #13 still needs explicit manual
closure under the host-process RSS memory policy if GitHub did not auto-close it.

| Item | Content | Status | Notes |
|---|---|---|---|
| Slice 1 — MDX preview | `remark-mdx`, non-executed placeholders, stale/error preview liveness | ✅ Merged PR #8 | Feature accepted; sanitizer still needs hardening below |
| Planning docs | M5 checklist, perf log, slice plan, WYSIWYG design draft | ✅ Merged PR #9 | `docs/wysiwyg-design.md` remains draft / not approved |
| Slice 2 — TSX highlighting | Vendored TSX grammar and MDX ESM/JSX injection highlighting | ✅ Merged PR #10 | Known multiline JSX limitation remains acceptable for M5 |
| Slice 4 — App icon/accent | App icon, accent color, deterministic generator | ✅ Merged PR #11 | First-pass art; final brand sign-off remains subjective |
| Slice 5 — Performance pass | Fixtures, PerformanceTests target, perf log, preview update optimization | ✅ Merged PR #15 | Infrastructure only; follow-up gates tracked below |
| Settings + themes | Settings panes and live editor/preview theme preferences from `agent.md` §11 | ❌ Not started | Required unless explicitly deferred with Decision Log entry |
| Security hardening | MDX sanitizer tightening, asset size/type guards, large image copy behavior | ❌ Not started | Needed before public alpha |
| Hidden perf gate — highlight | Visible-range highlight update <50 ms | ✅ Merged PR #20; issue #14 closed | Measured Markdown 17.918 ms max and MDX 22.670 ms max; not based on the 250 KB cutoff |
| Hidden perf gate — memory | 8 warm sessions + 2 live webviews <400 MB host-process RSS | ✅ Merged PR #21 via PR #20; issue #13 open pending manual closure | Measured 149.8 MB host RSS with 2 settled live webviews; WebKit helper memory remains diagnostic |

## Recommended next sequence

```text
0. PR #15, PR #20, and PR #21 have merged; issue #14 is closed.
1. Merge the memory-scope cleanup: keep the M5 gate scoped to host-process RSS, leave WebKit helper memory diagnostic, and close #13 manually if GitHub did not auto-close it.
2. Run a focused M5 security-hardening PR for sanitizer, asset guards, and large image handling.
3. Implement Settings + themes or explicitly defer them with a Decision Log entry. This can swap order with security if review capacity makes that easier.
4. Run `docs/m5-checklist.md` and update README, `agent.md`, `docs/perf-log.md`, and this plan to the final M5 state.
5. Only then approve `docs/wysiwyg-design.md` and start Phase 2 design spikes/build work.
```

The ordering above is intentionally conservative. `agent.md` §13 says Phase 2 begins only when M1–M5 are
complete and a WYSIWYG design doc is approved; the current repository is not there yet.

## Conflict hotspots

| File / area | Touched by | Handling |
|---|---|---|
| `project.yml` | PR #15 PerformanceTests, future test targets | Edit manifest only; run `make generate`; never commit hand-edited `.xcodeproj` |
| `docs/perf-log.md` | PR #15, #20, #21, memory-scope cleanup | Keep host RSS, WebKit helper diagnostics, and issue state explicit |
| `preview-src/src/pipeline.ts` | MDX sanitizer hardening, theme/remote image work | Sequence security hardening and theme/CSP changes carefully |
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
- **Settings + themes can be implemented after perf infrastructure, but before public alpha.** If deferred,
  the deferral must be explicit because `agent.md` currently includes it in M5.
- **Security hardening should happen before any public alpha.** MDX preview intentionally does not execute
  components, but sanitizer and asset policy still need tests against spoofing and large-file cases.

## Codex dispatch map

Use `docs/codex-handoff.md` as the copy/paste source for Codex prompts.

| Goal | Branch suggestion | Output |
|---|---|---|
| Memory scope cleanup | `m5-post-merge-review-fixes` | Clarifies #13 host-RSS policy and manual closure note |
| Settings + themes | `m5-settings-themes` | Implements `agent.md` §11 or documents a deferral |
| Security hardening | `m5-security-hardening` | Tightens sanitizer/assets and adds tests |
| CI/docs cleanup | `m5-ci-docs-sync` | Typecheck in CI and synchronized docs |

## Beyond M5

There is no accepted "M6" in `agent.md`. After M5, the roadmap is Phase 2 WYSIWYG, then unscheduled Phase 3
candidates. Recommended order after M5:

1. Approve `docs/wysiwyg-design.md`.
2. Run Phase 2 spikes for IME, undo, selection, and delimiter folding.
3. Ship inline-only WYSIWYG first: headings, emphasis, inline code, links, task checkbox.
4. Defer images, tables, Mermaid, and embedded block widgets until the inline engine is proven.
5. Keep two-pane source + preview mode permanently available.
