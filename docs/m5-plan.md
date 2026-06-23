# M5 Stabilization Plan & Dependency Order

> Living plan for M5 (MDX + polish, `agent.md` §14). M5 is too large for one PR, so it is split
> into PR-sized slices and follow-up gates. Status snapshot: **2026-06-24**.

## Current snapshot

M5 feature slices have mostly landed, but M5 is **not complete** because the hard performance gates and
some polish/hardening work remain open.

| Item | Content | Status | Notes |
|---|---|---|---|
| Slice 1 — MDX preview | `remark-mdx`, non-executed placeholders, stale/error preview liveness | ✅ Merged PR #8 | Feature accepted; sanitizer still needs hardening below |
| Planning docs | M5 checklist, perf log, slice plan, WYSIWYG design draft | ✅ Merged PR #9 | `docs/wysiwyg-design.md` remains draft / not approved |
| Slice 2 — TSX highlighting | Vendored TSX grammar and MDX ESM/JSX injection highlighting | ✅ Merged PR #10 | Known multiline JSX limitation remains acceptable for M5 |
| Slice 4 — App icon/accent | App icon, accent color, deterministic generator | ✅ Merged PR #11 | First-pass art; final brand sign-off remains subjective |
| Slice 5 — Performance pass | Fixtures, PerformanceTests target, perf log, preview update optimization | ✅ Merged PR #15 | Infrastructure only; hidden gates tracked below |
| Settings + themes | Settings panes and live editor/preview theme preferences from `agent.md` §11 | ❌ Not started | Required unless explicitly deferred with Decision Log entry |
| Security hardening | MDX sanitizer tightening, asset size/type guards, large image copy behavior | ❌ Not started | Needed before public alpha |
| Hidden perf gate — highlight | Visible-range highlight update <50 ms | ✅ This branch | Measured Markdown 17.918 ms max and MDX 22.670 ms max; not based on the 250 KB cutoff |
| Hidden perf gate — memory | 8 warm sessions + 2 live webviews <400 MB | ❌ Issue #13 open | PR #15 single-webview result is informational only |

## Recommended next sequence

```text
0. PR #15 has merged as M5 performance infrastructure.
1. Merge this branch to close issue #14: visible-range highlight instrumentation and <50 ms budget.
2. Implement issue #13: deterministic two-live-webview memory harness and <400 MB budget.
3. Implement Settings + themes or explicitly defer them with a Decision Log entry.
4. Run a focused M5 security-hardening PR.
5. Update docs/perf-log.md, docs/m5-checklist.md, README, and agent.md to match the final M5 state.
6. Only then approve docs/wysiwyg-design.md and start Phase 2 spikes/build work.
```

The ordering above is intentionally conservative. `agent.md` §13 says Phase 2 begins only when M1–M5 are
complete and a WYSIWYG design doc is approved; the current repository is not there yet.

## Conflict hotspots

| File / area | Touched by | Handling |
|---|---|---|
| `project.yml` | PR #15 PerformanceTests, future test targets | Edit manifest only; run `make generate`; never commit hand-edited `.xcodeproj` |
| `docs/perf-log.md` | PR #15, #13, #14 | Keep blocked/informational language until real measurements exist |
| `preview-src/src/pipeline.ts` | MDX sanitizer hardening, theme/remote image work | Sequence security hardening and theme/CSP changes carefully |
| `preview-src/src/index.ts` | Preview render caching, theme bridge, scroll sync | Require `npm run typecheck`, `npm test`, and regenerated dist when changed |
| `MarkdownEditorView` / `MarkdownTextView` | Visible-range highlighting, IME safety, future WYSIWYG | Do not start WYSIWYG folding until #14 lands |
| `agent.md` | Decision Log and milestone status | Update in the same PR when behavior or dependency policy changes |

## Risk notes

- **PR #15 must not be treated as full M5 completion.** It landed performance infrastructure while
  hidden gates remained tracked separately.
- **Visible-range highlighting is the most important pre-WYSIWYG engineering gate.** This branch
  measures the gate with visible-range-first parsing/apply; Phase 2 folding should still wait for
  the remaining M5 exits.
- **The two-webview memory gate may require a test-only harness.** Phase 1 has shared app-scoped state, so a
  deterministic harness is preferable to ambiguous manual multi-window behavior.
- **Settings + themes can be implemented after perf infrastructure, but before public alpha.** If deferred,
  the deferral must be explicit because `agent.md` currently includes it in M5.
- **Security hardening should happen before any public alpha.** MDX preview intentionally does not execute
  components, but sanitizer and asset policy still need tests against spoofing and large-file cases.

## Codex dispatch map

Use `docs/codex-handoff.md` as the copy/paste source for Codex prompts.

| Goal | Branch suggestion | Output |
|---|---|---|
| Review/finish PR #15 | continue `m5-perf-pass` or review PR #15 directly | PR #15 ready to merge or exact blockers |
| Visible-range highlight gate | `m5-visible-range-highlight` | Closes #14 with measured <50 ms update |
| Two-webview memory gate | `m5-two-webview-memory` | Closes #13 with measured <400 MB memory |
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
