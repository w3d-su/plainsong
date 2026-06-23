# Codex Handoff — M5 Stabilization and Phase 2 Gate

Status snapshot: 2026-06-23.

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
- Open / not complete:
  - PR #15 — performance infrastructure and perf log. This is mergeable, but it does **not** close the
    hidden M5 performance work by itself.
  - Issue #14 — visible-range highlight instrumentation and <50 ms budget.
  - Issue #13 — deterministic 8 warm sessions + 2 live webviews memory harness, <400 MB.
  - Settings + themes from `agent.md` §11 are still not implemented.
  - Security hardening around MDX sanitizer scope, preview asset guards, and large image handling still
    needs a focused pass.

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

# Goal 0 — Review and land PR #15 safely

```text
You are working in w3d-su/plainsong. Goal: review and finish PR #15 (`m5-perf-pass`) without overstating M5 completion.

Read first:
- agent.md §12, §14, §16, §17
- docs/m5-plan.md
- docs/perf-log.md
- GitHub PR #15 body
- Issues #13 and #14

Use a review subagent if available:
1. Performance reviewer: inspect PerformanceTests, fixtures, signposts, and docs/perf-log.md.
2. Preview reviewer: inspect the morphdom/highlight preservation optimization for correctness.
3. CI reviewer: inspect project.yml / Makefile / workflow coverage.

Tasks:
- Rebase/update PR #15 if needed.
- Confirm PerformanceTests is wired through project.yml and the app test scheme.
- Confirm perf fixtures are deterministic and not accidentally deleting useful existing fixtures.
- Confirm docs/perf-log.md honestly records:
  - typing latency as passing only if measured under 16 ms,
  - preview render as passing only if measured under 100 ms after debounce,
  - file open as passing only if measured under 300 ms,
  - visible-range highlighting as blocked until #14,
  - memory as informational until the 2-webview #13 harness exists.
- Run `make format` and `make test`.
- If preview-src changed, also run `cd preview-src && npm run typecheck && npm test`.

Acceptance:
- PR #15 is ready to merge or has a concise review comment listing exact blockers.
- docs/perf-log.md does not claim #13 or #14 are complete.
- Follow-up issues #13 and #14 remain open unless their full acceptance is implemented.
```

# Goal 1 — Issue #14: visible-range highlighting gate

```text
You are working in w3d-su/plainsong. Goal: implement the M5 visible-range highlighting gate from issue #14.

Read first:
- agent.md §6.2, §12, §16, §17
- Packages/EditorKit/Sources/EditorKit/MarkdownEditorView.swift
- Packages/EditorKit/Sources/EditorKit/MarkdownTextView.swift
- Packages/EditorKit/Sources/EditorKit/MarkdownSyntaxHighlighter.swift and parser/highlight mapper files
- docs/perf-log.md

Use subagents if available:
1. EditorKit architecture subagent: trace current visible line/range plumbing from STTextView to highlighter apply.
2. Performance test subagent: add deterministic signpost/XCTest coverage without depending on fragile UI automation.
3. IME safety subagent: verify styling apply is skipped/deferred while marked text exists and does not corrupt selection.

Implementation constraints:
- Keep source text as the model; do not mutate text for presentation.
- No synchronous full-document parse/apply on the typing hot path.
- Prefer visible-range-first tokenization/apply; dirty-range expansion is fine if documented.
- Preserve current selection, scroll position, undo behavior, and CJK IME marked text.
- Keep MarkdownCore UI-free.

Tasks:
- Plumb visible range information into the highlighting request/apply path.
- Add signposts or test hooks that measure highlight update time after an edit for visible ranges.
- Add/extend PerformanceTests for large Markdown and large MDX fixtures.
- Update docs/perf-log.md with measured values and environment.
- Add regression tests for selection/marked-text safety if feasible.

Acceptance:
- Highlight update visible range is measured under 50 ms on the target fixtures, or the PR explicitly explains the remaining blocker.
- The 250 KB inline parsing cutoff is not used as proof of passing.
- `make format` and `make test` pass.
```

# Goal 2 — Issue #13: deterministic two-webview memory harness

```text
You are working in w3d-su/plainsong. Goal: implement issue #13, the M5 memory gate.

Read first:
- agent.md §5, §12, §14, §16
- App workspace/window state files
- PreviewKit controller lifecycle
- PerformanceTests from PR #15 after it lands
- docs/perf-log.md

Use subagents if available:
1. App/windowing subagent: identify the least invasive way to create two live preview webviews deterministically.
2. PreviewKit lifecycle subagent: ensure both webviews settle before memory capture and are released when the harness ends.
3. Performance harness subagent: implement RSS measurement and threshold assertion.

Implementation constraints:
- Do not accidentally start full Phase 2 or independent multi-window state unless unavoidable.
- The harness may be test-only if that gives deterministic 2 live previews.
- The gate is exactly: 8 warm sessions + 2 live preview webviews, resident memory <400 MB.
- Keep existing single-webview measurement marked informational.

Tasks:
- Add or document a deterministic workflow/harness with 8 warm sessions and 2 live preview webviews.
- Wait for both previews to finish rendering before memory capture.
- Assert <400 MB if deterministic on CI; if CI variance is too high, make the CI behavior explicit and keep a local/manual gate in docs.
- Update docs/perf-log.md with environment, value, and pass/fail.

Acceptance:
- docs/perf-log.md has a real 2-webview measurement.
- The test or manual harness is reproducible by another agent/human.
- `make format` and `make test` pass.
```

# Goal 3 — M5 Settings + themes

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

# Goal 4 — M5 security hardening

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

# Goal 5 — CI/docs cleanup

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
- Ensure docs link to #13, #14, and #15 where relevant.
- Add Decision Log entries for any behavior or policy changes.

Acceptance:
- CI catches preview TypeScript type errors.
- README and docs do not claim M5 is complete until #13 and #14 are done.
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
