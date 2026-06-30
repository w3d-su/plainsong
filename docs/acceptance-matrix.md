# Acceptance Matrix

Status snapshot: 2026-06-27.

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
| M5 MDX preview | `.mdx` preview pipeline with non-executed placeholders, error liveness, sanitizer, fixtures | PR #8 merged; PR #24 hardened sanitizer policy | Accepted |
| M5 TSX highlighting | MDX ESM/JSX regions receive TSX injection highlighting | PR #10 merged | Accepted with documented multiline JSX limitation |
| M5 icon/accent | App icon and accent assets exist | PR #11 merged | Accepted as first-pass art; product sign-off still subjective |
| M5 settings/themes | Settings scene and theme preferences from `agent.md` §11 / issue #16 | PR #26 added settings, persistence, live editor/preview updates, and remote-image policy | Accepted |
| M5 performance gates | Typing, preview render, file open, visible-range highlight, and host RSS budgets | PR #15, #20, #21, #22, `docs/perf-log.md` | Accepted |
| M5 security hardening | Sanitizer, asset scheme, remote load policy, large image handling tested | PR #24 and PR #27 | Accepted; keep as regression risk |
| M5 CI preview typecheck | CI runs preview TypeScript typecheck and tests | PR #22 | Accepted |
| M5 final editor-input acceptance | Broken-MDX edit/recovery, MDX completion popup tag-context pass, and fenced-code completion suppression | PR #32 and PR #33 | Accepted |
| Phase 2 WYSIWYG design gate | M1-M5 accepted and `docs/wysiwyg-design.md` approved | PR #36 and follow-up design notes | Accepted; superseded by the Experimental mode checklist |
| Phase 2 WYSIWYG Experimental mode | Off-by-default Settings gate, source/source+preview regressions preserved, native gates complete, stable promotion blocked | PR #41-#49 plus 2026-06-27 manual sign-off in `docs/wysiwyg-design.md` §19 and `docs/wysiwyg-release-checklist.md` | Accepted as Experimental/off by default only |

## Current release posture

| Release target | Recommendation | Reason |
|---|---|---|
| Local dogfood | Yes | Core editor/workspace/preview features are in place. |
| Private alpha with trusted users | Maybe, for trusted local dogfood only | M5 is accepted, but release hardening is still not final. |
| Public alpha | No | License choice, signing, hardened runtime, notarization, and release packaging are still not final. |
| Phase 2 WYSIWYG Experimental dogfood | Yes, off by default | Native input/selection gates are complete and manual UI sign-off passed; users must opt in through `WYSIWYG mode (Experimental)`. |
| Phase 2 WYSIWYG stable/default | No | Stable/default promotion remains blocked by `docs/wysiwyg-release-checklist.md`; do not remove the Experimental label or turn it on by default without the explicit promotion gate and Decision Log entry. |

## M5 exit checklist

M5 accepted after PR #33 because all items below are true:

- [x] PR #15 merged or superseded by equivalent performance infrastructure.
- [x] Issue #14 closed with measured <50 ms visible-range highlighting.
- [x] Issue #13 closed under the host-process RSS scope decision.
- [x] Settings + themes from `agent.md` §11 implemented for issue #16, with custom JSON/user CSS deferred by Decision Log.
- [x] Security hardening PR landed for MDX sanitizer and asset handling; PR #24 closed issue #17 and PR #27 fixed SVG policy drift.
- [x] CI/docs cleanup landed with preview TypeScript typecheck coverage.
- [x] `docs/perf-log.md` filled with environment, commit, fixtures, values, and pass/fail results for the performance gates.
- [x] `docs/m5-checklist.md` passes manually. PR #32 live-verified broken-MDX edit/recovery and added MarkdownCore regression coverage for fenced-code component completion suppression; PR #33 live-verified the imported-component popup in tag context and no popup inside fenced code.
- [x] README, `agent.md`, and planning docs no longer contain stale PR #26/#27 milestone claims.

M5 final status: **Accepted** as of 2026-06-25 after PR #33.
