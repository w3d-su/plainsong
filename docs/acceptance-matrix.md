# Acceptance Matrix

Status snapshot: 2026-06-25.

This matrix is the short operational view of `agent.md` milestones. It does not replace
`agent.md`; it records whether the evidence currently on the repository is enough to treat
a milestone or gate as accepted.

## Milestone state

| Area | Required acceptance | Evidence / reference | State |
|---|---|---|---|
| M0 scaffold | Generated project builds, CI exists, package tests run | `project.yml`, `Makefile`, CI workflow | Accepted |
| M1 editor core | Open/save, autosave/session restore, dirty indicator, status stats, no large-doc fallback lag | Landed before current M5 work | Accepted |
| M1.5 parser highlighting | Parser-backed Markdown/frontmatter/fence highlighting replaces regex fallback | Landed before current M5 work | Accepted |
| M2 live preview | Offline WKWebView preview, GFM, KaTeX, Mermaid, checkbox writeback, scroll sync, preview toggle | Landed before current M5 work | Accepted |
| M3 workspace | Folder workspace, sidebar, FSEvents, file operations, recents/bookmarks, LRU sessions | PR #2 merged | Accepted |
| M4 authoring | Formatting/editing behaviors, completion, frontmatter, smart paste, image drag/drop, table helper | PR #4, #5, #6, #7 merged | Accepted |
| M5 MDX preview | `.mdx` preview pipeline with non-executed placeholders, error liveness, sanitizer, fixtures | PR #8 merged; PR #24 hardened sanitizer policy | Accepted for feature scope and current security policy |
| M5 TSX highlighting | MDX ESM/JSX regions receive TSX injection highlighting | PR #10 merged | Accepted with documented multiline JSX limitation |
| M5 icon/accent | App icon and accent assets exist | PR #11 merged | Accepted as first-pass art; product sign-off still subjective |
| M5 settings/themes | Settings scene and theme preferences from `agent.md` §11 / issue #16 | PR #26 added General, Editor, Preview, and Files settings; UserDefaults persistence; live editor/preview setting updates; and tested remote-image policy | Accepted for feature scope; manual checklist still required for M5 |
| M5 performance infrastructure | Dedicated performance fixtures/tests and `docs/perf-log.md` measurements | PR #15 merged | Accepted as infrastructure; not full M5 completion |
| M5 performance: typing | <16 ms typing latency | PR #15 reports 0.254 ms max | Accepted |
| M5 performance: preview render | <100 ms after debounce for 100 KB doc | PR #15 local result bundle reports Markdown median 46.631 ms, MDX median 14.556 ms; GitHub runner timing is informational only | Accepted |
| M5 performance: file open | <300 ms to first paint for 500 KB doc | PR #15 reports 33.765 ms | Accepted |
| M5 performance: visible-range highlight | <50 ms visible-range highlight update after edit | PR #20 records Markdown 17.918 ms max and MDX 22.670 ms max in `docs/perf-log.md`; issue #14 closed | Accepted |
| M5 performance: memory | <400 MB host-process RSS with 8 warm sessions + 2 live webviews | PR #21 records 149.8 MB host RSS with 8 warm sessions and 2 settled live webviews in `docs/perf-log.md`; WebKit helper RSS is diagnostic; issue #13 closed after PR #22 clarified scope | Accepted |
| M5 security hardening | Sanitizer, asset scheme, remote load policy, large image handling tested | PR #24 merged and closed issue #17 with no-inline-style sanitizer policy, pre-sanitize script-like element drops, bounded raster-only assets, and PR #27 SVG/path rejection | Accepted; keep as regression risk |
| M5 CI preview typecheck | CI runs `cd preview-src && npm run typecheck` and still runs preview tests | PR #22 added the CI step; `make test` still runs preview tests only; issue #18 closed | Accepted |
| Phase 2 WYSIWYG gate | M1-M5 accepted and `docs/wysiwyg-design.md` approved | Draft doc exists from PR #9 | Design only; implementation blocked until M5 is accepted and the design doc is approved |

## Current release posture

| Release target | Recommendation | Reason |
|---|---|---|
| Local dogfood | Yes | Core editor/workspace/preview features are in place. |
| Private alpha with trusted users | Maybe, after the M5 manual checklist passes | Performance, security, settings, content-folder, launch-stability, and Open Recent checks are in place, but the final manual checklist still has unchecked editor-input items. |
| Public alpha | No | License choice, signing, hardened runtime, notarization, and release packaging are still not final. |
| Phase 2 WYSIWYG implementation | No | M5 is not accepted while checklist blockers remain, and `agent.md` also requires design approval first. |

## M5 exit checklist

M5 should not be called accepted until all items below are true:

- [x] PR #15 merged or superseded by equivalent performance infrastructure.
- [x] Issue #14 closed with measured <50 ms visible-range highlighting.
- [x] Issue #13 closed under the host-process RSS scope decision.
- [x] Settings + themes from `agent.md` §11 implemented for issue #16, with custom JSON/user CSS deferred by Decision Log.
- [x] Security hardening PR landed for MDX sanitizer and asset handling; PR #24 closed issue #17 and PR #27 fixed SVG policy drift.
- [x] CI/docs cleanup landed with preview TypeScript typecheck coverage.
- [x] `docs/perf-log.md` filled with environment, commit, fixtures, values, and pass/fail results for the performance gates.
- [ ] `docs/m5-checklist.md` passes manually. The 2026-06-25 sweeps fixed and rechecked editor-to-preview scroll sync, completed the real Next.js content-folder/settings/icon/polish/switching checks, and PR #30 fixed the launch stability and optional Open Recent persistence blockers. The `m5-editor-input-checklist` follow-up live-verified the broken-MDX edit/reintroduce recovery loop and added MarkdownCore regression coverage for fenced-code component completion suppression. The remaining blockers are:
  - Live UI completion popup for imported MDX components after typing `<` in a tag context.
  - Live UI confirmation that MDX component completion does not appear inside fenced code or obvious non-tag contexts.
- [x] README, `agent.md`, and planning docs no longer contain stale PR #26/#27 milestone claims.

M5 final status: **Feature-complete but not accepted** as of 2026-06-25 because `docs/m5-checklist.md` does not fully pass.
