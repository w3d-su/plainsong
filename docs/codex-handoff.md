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
- Open / not complete:
  - Issue #13 is still open in GitHub even though PR #21 measured 149.8 MB host RSS. Close it manually
    if the host-process RSS scope decision remains accepted; WebKit helper memory stays diagnostic.
  - Issue #16 — Settings + themes from `agent.md` §11 are still not implemented.
  - Issue #17 — security hardening around MDX sanitizer scope, preview asset guards, and large image
    handling still needs a focused pass.
  - Issue #18 — preview TypeScript typecheck should be explicit in CI; this cleanup PR should close it.

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

# Completed reference — landed performance work

- PR #15 merged on 2026-06-23 as M5 performance infrastructure.
- PR #20 merged on 2026-06-24 and closed issue #14 with measured visible-range highlighting.
- PR #21 merged into the PR #20 stack and is included on `main`; it measured 149.8 MB host-process RSS
  with 8 warm sessions and 2 settled live webviews. If issue #13 is still open, close it manually with
  the host-process RSS scope note from `docs/perf-log.md`.

# Goal 0 — M5 Settings + themes (#16)

```text
You are working in w3d-su/plainsong. Goal: implement M5 Settings + themes from agent.md §11.

Read first:
- agent.md §6.2, §7.1, §11, §17
- App settings scene / AppState / preferences files
- EditorKit theme files
- PreviewKit theme bridge and preview-src styles
- docs/m5-checklist.md

Use subagents if available:
1. SwiftUI settings subagent: implement General, Editor, Preview, and Files panes with UserDefaults-backed settings.
2. Editor theme subagent: ensure editor font/line numbers/theme changes apply live without reloading the document.
3. Preview theme subagent: wire preview theme and optional user CSS through the existing bridge safely.
4. Security subagent: ensure any remote image preference changes CSP/navigation policy intentionally and is tested.

Scope:
- General: default folder, autosave interval.
- Editor: font, size, line numbers, typewriter sync.
- Preview: theme, allow remote images.
- Files: image-paste asset folder pattern, default extension `.md`/`.mdx`.

Implementation constraints:
- UserDefaults is fine; do not add a persistence dependency.
- If bridge protocol changes, mirror Swift/TS constants and regenerate preview assets.
- Do not relax CSP broadly. If allowing remote images, only allow what the setting requires and keep scripts/network execution blocked.

Acceptance:
- Settings are visible in the macOS Settings scene and persist across relaunch.
- Editor and preview settings apply live where reasonable.
- Preview remote image policy is tested and documented.
- `make format`, `make test`, and `cd preview-src && npm run typecheck && npm test` pass if preview-src changed.
```

# Goal 1 — M5 security hardening (#17)

```text
You are working in w3d-su/plainsong. Goal: harden MDX preview sanitization and local asset handling before public alpha.

Read first:
- agent.md §5, §7.1, §9, §16
- preview-src/src/pipeline.ts and sanitizer schema
- PreviewKit asset URL scheme handler
- WorkspaceKit/ImageAssetStore or equivalent image-copy path
- docs/risk-register.md

Use subagents if available:
1. Preview sanitizer subagent: tighten `rehype-sanitize` schema and add malicious MDX/HTML snapshot tests.
2. Asset handler subagent: add path, MIME/type, and size guards to the asset scheme handler.
3. Image import subagent: replace large-file `Data(contentsOf:)` copies with streaming or FileManager copy where appropriate.
4. Regression test subagent: add tests for symlink escape, `../`, huge files, unsupported MIME, and blocked style spoofing.

Tasks:
- Remove broad `style` allowance from the sanitizer unless a narrow allowlist is required for a specific internal feature.
- Add tests for `position: fixed`, high `z-index`, giant dimensions, background URL, event handlers, and script-like payloads.
- Enforce preview asset containment, supported file types, and maximum size.
- Avoid reading large image/asset files entirely into memory where streaming/copyItem is possible.
- Document any size limits and rationale.

Acceptance:
- MDX placeholders still render, but unsafe styles/attributes are stripped.
- Asset tests prove path containment and size/type rejection.
- Large image imports do not spike memory via whole-file Data loads.
- `make format`, `make test`, and `cd preview-src && npm run typecheck && npm test` pass if preview-src changed.
```

# Goal 2 — CI/docs cleanup (#18)

```text
You are working in w3d-su/plainsong. Goal: make CI and docs reflect the actual M5 state.

Read first:
- .github/workflows/ci.yml
- Makefile
- README.md
- agent.md §12, §14, §15–§18
- docs/m5-plan.md
- docs/acceptance-matrix.md

Tasks:
- Add `cd preview-src && npm run typecheck` to CI if it is not already covered.
- Keep `make test` behavior documented accurately.
- Update README/agent.md/docs if any milestone status is stale.
- Ensure docs link to PR #15/#20/#21 and issues #13/#14/#16/#17/#18 where relevant.
- Add Decision Log entries for any behavior or policy changes.

Acceptance:
- CI catches preview TypeScript type errors.
- README and docs do not claim M5 is complete until #16/#17 are resolved and #13 closure is explicit; #14 is already closed.
- `make format` and `make test` pass.
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
- No Phase 2 implementation PR starts until M5 performance/security gates are accepted.
```
