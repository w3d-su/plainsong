# Plainsong

A native macOS Markdown/MDX editor, built with Swift (SwiftUI shell + AppKit/TextKit 2
editor core) — in the spirit of Typora, tuned for blog authoring workflows
(Astro/Next.js content folders, YAML frontmatter, CJK-friendly).

**Status: in development.** M0-M5 have landed and M5 is accepted.
M5 performance and security hardening have landed: PR #15 added the infrastructure,
PR #20 measured visible-range highlighting, PR #21 measured the two-webview
host-process RSS memory gate, and PR #24/#27 closed issue #17 with the MDX
sanitizer/asset/SVG policy. PR #26 landed Settings/themes and closed #16. The
2026-06-25 final sweeps fixed scroll sync, launch/Open Recent, MDX error liveness, and
live MDX completion-popup checklist blockers; `docs/m5-checklist.md` now passes. Do not
start Phase 2 WYSIWYG implementation until the WYSIWYG design gate is approved.

## Development

Everything an agent or human needs to work on this codebase lives in
[`agent.md`](agent.md) — architecture, layering rules, milestone roadmap, and the
Decision Log. Read it before writing code.

Useful planning and handoff docs:

- [`docs/m5-plan.md`](docs/m5-plan.md) — current M5 stabilization sequence.
- [`docs/codex-handoff.md`](docs/codex-handoff.md) — Codex-ready goal/subagent prompts.
- [`docs/acceptance-matrix.md`](docs/acceptance-matrix.md) — milestone gates and evidence.
- [`docs/risk-register.md`](docs/risk-register.md) — current risks and mitigations.

```sh
make bootstrap   # xcodegen, swiftformat, swiftlint, node + npm ci
make build       # generates Plainsong.xcodeproj and builds
make test        # Swift package tests + app tests + preview vitest suite
cd preview-src && npm run typecheck
```

Requires Xcode 16+ and macOS 14+.

## License

Not yet licensed for redistribution; a license will be chosen before the first
public release. All rights reserved until then.
