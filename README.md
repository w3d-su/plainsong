# Plainsong

A native macOS Markdown/MDX editor, built with Swift (SwiftUI shell + AppKit/TextKit 2
editor core) — in the spirit of Typora, tuned for blog authoring workflows
(Astro/Next.js content folders, YAML frontmatter, CJK-friendly).

**Status: in development.** M0–M4 have landed and M5 is in stabilization. The M5
performance work is mostly measured: PR #15 added the infrastructure, PR #20 measured
visible-range highlighting, and PR #21 measured the two-webview host-process RSS memory
gate. M5 is still not complete because Settings/themes (#16) and security hardening (#17)
remain open. Do not start Phase 2 WYSIWYG implementation until M5 is complete or any
remaining scope is explicitly deferred in `agent.md`.

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
