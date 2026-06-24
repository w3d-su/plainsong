# Codex Handoff — M5 Stabilization and Phase 2 Gate

Status snapshot: 2026-06-24.

This document turns the current review findings into Codex-ready work packages. It is intentionally
operational: each section can be copied into Codex as a single goal, or split into subagents when the
work crosses Swift/AppKit, PreviewKit, and preview-src.

## Current state

- `main` has M0–M4 plus most M5 feature slices landed.
- Merged M5 slices:
  - PR #8 — MDX preview placeholders.
  - PR #9 — M5 planning docs and draft WYSIWYG design.
  - PR #10 — TSX injection highlighting for MDX.
  - PR #11 — app icon and accent color.
  - PR #15 — performance infrastructure, fixtures, and perf log.
  - PR #20 — visible-range highlighting gate; closed issue #14.
  - PR #21 — deterministic two-live-webview host-process RSS memory harness; included on `main` through PR #20.
  - PR #22 — post-merge docs/CI/scheduling cleanup; closed issues #13 and #18.
  - PR #24 — MDX preview/asset security hardening; closed issue #17.
- Current M5 slice in review:
  - Issue #16 — Settings + themes from `agent.md` §11 are implemented in the current PR; keep any review
    fixes scoped to Settings/themes and do not expand into Phase 2.
- Open / not complete:
  - `docs/m5-checklist.md` still needs to be run manually.
  - Final M5 status/stale-doc sweep still needs to land after the checklist.
  - Phase 2 WYSIWYG remains blocked until M5 exits and `docs/wysiwyg-design.md` is approved.

## Rules for every Codex run

1. Read `agent.md` before editing. If the task conflicts with it, update `agent.md` and the Decision Log in
   the same PR or stop and explain the conflict.
2. One milestone task per branch/PR. Branch names must follow `m<N>-<slug>` or a scoped review-fix name.
3. Never edit or commit `.xcodeproj`; edit `project.yml` and run `make generate` when target membership changes.
4. No new dependencies unless the PR adds a Decision Log entry with alternatives considered.
5. Logic changes need tests. Preview bridge changes need mirrored Swift/TS protocol changes and a regenerated
   preview bundle.
6. Do not fake M5 performance passes. If a gate is blocked, keep it explicitly blocked/informational in
   `docs/perf-log.md`.
7. Run the relevant verification before declaring done: `make format`, `make test`, and, when preview-src
   changed, `cd preview-src && npm run typecheck && npm test`.

---

# Completed reference — landed performance/security/settings work

- PR #15 merged on 2026-06-23 as M5 performance infrastructure.
- PR #20 merged on 2026-06-24 and closed issue #14 with measured visible-range highlighting.
- PR #21 merged into the PR #20 stack and is included on `main`; it measured 149.8 MB host-process RSS
  with 8 warm sessions and 2 settled live webviews.
- PR #22 merged on 2026-06-24, clarified the host-process RSS scope, added preview TypeScript typecheck
  to CI, and closed issues #13 and #18.
- PR #24 merged on 2026-06-24 and closed issue #17 with the M5 security policy: no inline sanitized
  HTML style, script-like element drops before sanitize, bounded raster-only preview/import assets, and
  SVG rejection until a separate sanitizer/design exists.
- PR #27 merged on 2026-06-24 and removed stale inline SVG/path sanitizer allowances so source-authored
  SVG/path payloads are dropped before sanitize.
- This PR implements issue #16 Settings/themes with UserDefaults-backed panes, live editor/preview
  preferences, and an HTTPS-only remote image opt-in. Custom editor-theme JSON and user CSS remain
  deferred by Decision Log.

# Goal 0 — M5 checklist and final status sweep

```text
You are working in w3d-su/plainsong. Goal: run the M5 manual checklist and make the final M5 status/docs update.

Read first:
- README.md
- agent.md §11, §12, §14, §17
- docs/m5-checklist.md
- docs/acceptance-matrix.md
- docs/m5-plan.md
- docs/risk-register.md
- docs/perf-log.md

Use subagents if available:
1. Manual checklist subagent: walk `docs/m5-checklist.md` in a disposable workspace and capture blockers/evidence.
2. Docs sweep subagent: search README/agent/docs for stale #13/#14/#16/#17/M5 claims.
3. Release posture subagent: keep private-alpha/public-alpha language separated from M5 completion.

Tasks:
- Run the automated checks requested by the checklist.
- Launch Plainsong and perform the manual M5 checklist.
- Record any final evidence or blockers without faking passes.
- Update README, `agent.md`, `docs/acceptance-matrix.md`, `docs/m5-plan.md`, `docs/risk-register.md`,
  `docs/codex-handoff.md`, and `docs/perf-log.md` only as evidence warrants.
- If all gates pass, mark M5 complete in docs; otherwise keep the exact remaining blocker explicit.

Non-goals:
- Do not start Phase 2 WYSIWYG.
- Do not reopen security or Settings implementation scope unless the checklist finds a regression.

Acceptance:
- M5 checklist evidence is recorded honestly.
- M5 is called complete only if the full checklist passes and docs no longer contain stale milestone claims.
- Phase 2 remains design/spike-only until M5 exits and the design doc is approved.
```

# Phase 2 gate prompt — design/spike only, no WYSIWYG feature build yet

```text
You are working in w3d-su/plainsong. Goal: prepare Phase 2 WYSIWYG design/spikes after M5 gates are complete. Do not build full WYSIWYG yet.

Read first:
- agent.md §13
- docs/wysiwyg-design.md
- docs/acceptance-matrix.md
- docs/risk-register.md

Use subagents if available:
1. TextKit 2 folding spike subagent: prototype delimiter folding/reveal without text mutation.
2. IME spike subagent: test Traditional Chinese marked text through bold/italic/link/inline-code ranges.
3. Undo/selection spike subagent: prove undo grouping and selection movement across folded tokens.
4. Product scope subagent: keep v1 to inline-only WYSIWYG; table/mermaid/image widgets stay deferred.

Acceptance for the design gate:
- docs/wysiwyg-design.md lists exact v1 scope, deferred scope, risks, and acceptance tests.
- Spike results cover IME, undo, selection, and source round-trip.
- No Phase 2 implementation PR starts until M5 is complete or any remaining M5 scope is explicitly deferred.
```
