# Plainsong

A native macOS Markdown/MDX editor, built with Swift (SwiftUI shell + AppKit/TextKit 2
editor core) — in the spirit of Typora, tuned for blog authoring workflows
(Astro/Next.js content folders, YAML frontmatter, CJK-friendly).

**Status: in development.** M0–M4 have landed and M5 is in stabilization. The next
focus is to finish the M5 performance/security gates before any Phase 2 WYSIWYG work:
`#15` adds performance infrastructure, while `#13` (two-webview memory) and `#14`
(visible-range highlighting) remain the critical follow-up gates. Do not start Phase 2
implementation until the M5 gates are measured and documented.

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
```

Requires Xcode 16+ and macOS 14+.

## License

Not yet licensed for redistribution; a license will be chosen before the first
public release. All rights reserved until then.
