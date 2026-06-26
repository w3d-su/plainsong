# Codex Handoff — M5 Stabilization and Phase 2 Gate

Status snapshot: 2026-06-25.

This document turns the current review findings into Codex-ready work packages. It is intentionally
operational: each section can be copied into Codex as a single goal, or split into subagents when the
work crosses Swift/AppKit, PreviewKit, and preview-src.

## Current state

- `main` has M0–M4 plus M5 feature implementation landed.
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
  - PR #28 — recorded the first final-checklist blocker sweep.
  - PR #29 — editor-to-preview scroll-sync checklist fix.
  - PR #30 — workspace launch stability, Open Recent failure handling, and final checklist evidence sync.
  - PR #32 — broken-MDX edit/recovery evidence and MarkdownCore fenced-code completion suppression.
- M5 accepted:
  - `docs/m5-checklist.md` now passes after PR #33. PR #33 is the final M5 acceptance PR: it
    follows PR #32's broken-MDX edit/reintroduce recovery evidence and MarkdownCore fenced-code
    component completion suppression, then live-verified the STTextView MDX completion popup in both
    tag-context and fenced-code contexts.
- Open gate:
  - Phase 2 WYSIWYG remains blocked until `docs/wysiwyg-design.md` is approved.

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
- PR #28 merged on 2026-06-24 and recorded the first final-checklist blockers without accepting M5.
- PR #29 merged on 2026-06-25 and fixed/rechecked editor-to-preview scroll sync without accepting M5.
- PR #30 merged on 2026-06-25 and fixed two checklist blockers without accepting M5: the workspace
  launch AppKit constraint-loop crash by using a stable `HStack` shell instead of `NavigationSplitView`,
  and optional Open Recent persistence failures by treating them as best-effort. The `HStack` is the M5
  stability tradeoff; restoring an adjustable/native sidebar is post-M5 polish.
- PR #32 merged on 2026-06-26 with broken-MDX edit/recovery evidence and MarkdownCore fenced-code
  component completion suppression.
- PR #33 is the final M5 acceptance PR. It live-verifies MDX component completion popup behavior in
  tag context and no popup inside fenced code.

# Completed reference — M5 checklist blocker resolution

The final M5 checklist blocker goal is complete in PR #33. Final evidence lives in
`docs/m5-checklist.md`: broken-MDX edit/recovery works, live STTextView MDX component completions
appear after typing `<` in a tag context, and the component popup does not appear inside fenced code.
PR #32 is already merged and should not remain an active Codex goal.

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
