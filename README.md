# Plainsong

A native macOS Markdown/MDX editor, built with Swift (SwiftUI shell + AppKit/TextKit 2
editor core) — in the spirit of Typora, tuned for blog authoring workflows
(Astro/Next.js content folders, YAML frontmatter, CJK-friendly).

**Status: in development.** Milestones M0–M2 complete: editor core with tree-sitter
highlighting, autosave/session restore, and a fully offline side-by-side rendered
preview (GFM tables, KaTeX, Mermaid, synchronized scrolling, ⌘⇧P toggle).

## Development

Everything an agent or human needs to work on this codebase lives in
[`agent.md`](agent.md) — architecture, layering rules, milestone roadmap, and the
Decision Log. Read it before writing code.

```sh
make bootstrap   # xcodegen, swiftformat, swiftlint, node + npm ci
make build       # generates Plainsong.xcodeproj and builds
make test        # Swift package tests + app tests + preview vitest suite
```

Requires Xcode 16+ and macOS 14+.

## License

Not yet licensed for redistribution; a license will be chosen before the first
public release. All rights reserved until then.
