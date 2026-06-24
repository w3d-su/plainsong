# Acceptance Matrix

Status snapshot: 2026-06-24.

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
| M5 MDX preview | `.mdx` preview pipeline with non-executed placeholders, error liveness, sanitizer, fixtures | PR #8 merged; PR #24 hardened sanitizer and asset policy | Accepted |
| M5 TSX highlighting | MDX ESM/JSX regions receive TSX injection highlighting | PR #10 merged | Accepted with documented multiline JSX limitation |
| M5 icon/accent | App icon and accent assets exist | PR #11 merged | Accepted as first-pass art; product sign-off still subjective |
| M5 settings/themes | Settings scene and theme preferences from `agent.md` §11 | Issue #16 remains open; no implementation found in current search | Not started |
| M5 performance infrastructure | Dedicated performance fixtures/tests and `docs/perf-log.md` measurements | PR #15 merged | Accepted as infrastructure; not full M5 completion |
| M5 performance: typing | <16 ms typing latency | PR #15 reports 0.254 ms max | Accepted |
| M5 performance: preview render | <100 ms after debounce for 100 KB doc | PR #15 local result bundle reports Markdown median 46.631 ms, MDX median 14.556 ms; GitHub runner timing is informational only | Accepted |
| M5 performance: file open | <300 ms to first paint for 500 KB doc | PR #15 reports 33.765 ms | Accepted |
| M5 performance: visible-range highlight | <50 ms visible-range highlight update after edit | PR #20 records Markdown 17.918 ms max and MDX 22.670 ms max in `docs/perf-log.md`; issue #14 closed | Accepted |
| M5 performance: memory | <400 MB host-process RSS with 8 warm sessions + 2 live webviews | PR #21 records 149.8 MB host RSS with 8 warm sessions and 2 settled live webviews in `docs/perf-log.md`; WebKit helper RSS is diagnostic; issue #13 closed after PR #22 clarified scope | Accepted |
| M5 security hardening | Sanitizer, asset scheme, local image type/size policy, large image handling tested | PR #24 merged and closed issue #17 with sanitizer, asset type/size, and large image-copy evidence | Accepted |
| M5 CI preview typecheck | CI runs `cd preview-src && npm run typecheck` and still runs preview tests | PR #22 added the CI step; `make test` still runs preview tests only; issue #18 closed | Accepted |
| Phase 2 WYSIWYG gate | M1–M5 complete and `docs/wysiwyg-design.md` approved | Draft doc exists from PR #9 | Design only; implementation blocked until M5 complete |

## Current release posture

| Release target | Recommendation | Reason |
|---|---|---|
| Local dogfood | Yes | Core editor/workspace/preview features are in place. |
| Private alpha with trusted users | Maybe, after #16 and M5 checklist | Performance and security hardening have landed, but Settings/themes and final M5 checklist/status review remain open. |
| Public alpha | No | License, signing, notarization, and release hardening are not final. |
| Phase 2 WYSIWYG implementation | No | `agent.md` requires M1–M5 complete and design approval first; M5 is still incomplete while #16 remains open or undeferred. |

## M5 exit checklist

M5 should not be called complete until all items below are true:

- [x] PR #15 merged or superseded by equivalent performance infrastructure.
- [x] Issue #14 closed with measured <50 ms visible-range highlighting.
- [x] Issue #13 closed under the host-process RSS scope decision.
- [ ] Settings + themes from `agent.md` §11 implemented or explicitly deferred with a Decision Log entry.
- [x] Security hardening PR landed for MDX sanitizer and asset handling.
- [x] CI/docs cleanup landed with preview TypeScript typecheck coverage.
- [x] `docs/perf-log.md` filled with environment, commit, fixtures, values, and pass/fail results for the performance gates.
- [ ] `docs/m5-checklist.md` passes manually.
- [ ] Final stale-doc check confirms README, `agent.md`, and planning docs no longer contain stale milestone claims.
