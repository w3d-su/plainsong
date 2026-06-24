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
  - PR #26 — Settings/themes; closed issue #16.
  - PR #27 — SVG preview security policy alignment.
- Open / not accepted:
  - `docs/m5-checklist.md` has remaining unchecked manual blockers from the 2026-06-24 final sweep.
  - Phase 2 WYSIWYG remains blocked until M5 is accepted and `docs/wysiwyg-design.md` is approved.

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
- PR #26 merged on 2026-06-24 and closed issue #16 with UserDefaults-backed Settings panes, live
  editor/preview preferences, and an HTTPS-only remote image opt-in. Custom editor-theme JSON and
  user CSS remain deferred by Decision Log.

# Goal 0 — M5 checklist blocker resolution

```text
You are working in w3d-su/plainsong. Goal: resolve the remaining unchecked M5 checklist blockers without adding new M5 features.

Read first:
- README.md
- agent.md §11, §12, §14, §17
- docs/m5-checklist.md
- docs/acceptance-matrix.md
- docs/m5-plan.md
- docs/risk-register.md
- docs/perf-log.md

Use subagents if available:
1. Manual checklist subagent: complete the unchecked app UI and real-content items in `docs/m5-checklist.md`.
2. Settings/theme subagent: verify Settings panes, preview/editor theme changes, Mermaid theme behavior, and persistence.
3. Real-content subagent: run a real Astro or Next.js content folder through the remaining MDX acceptance checks.

Tasks:
- Launch Plainsong from the current branch and finish only the unchecked items in `docs/m5-checklist.md`.
- Record evidence or blockers without faking passes.
- If all gates pass, mark M5 accepted in README, `agent.md`, `docs/acceptance-matrix.md`,
  `docs/m5-plan.md`, `docs/risk-register.md`, and `docs/codex-handoff.md`.
- If any item still fails, keep M5 not accepted and document the exact blocker.

Non-goals:
- Do not start Phase 2 WYSIWYG.
- Do not reopen security or Settings implementation scope unless the checklist finds a regression.

Acceptance:
- M5 checklist evidence is recorded honestly.
- M5 is called accepted only if the full checklist passes.
- Phase 2 remains design/spike-only until M5 is accepted and the design doc is approved.
```

# Phase 2 gate prompt — design/spike only, no WYSIWYG feature build yet

```text
You are working in w3d-su/plainsong. Goal: prepare Phase 2 WYSIWYG design/spikes after M5 is accepted. Do not build full WYSIWYG yet.

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
- No Phase 2 implementation PR starts until M5 is accepted and the WYSIWYG design doc is approved.
```
