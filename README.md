# Plainsong

English | [繁體中文](README.zh-Hant.md)

A native macOS Markdown/MDX editor, built with Swift (SwiftUI shell + AppKit/TextKit 2
editor core) — in the spirit of Typora, tuned for blog authoring workflows
(Astro/Next.js content folders, YAML frontmatter, CJK-friendly).

**Status: public alpha.** Builds are unsigned and published on
[GitHub Releases](https://github.com/w3d-su/plainsong/releases). Everything listed under
Features is on `main`; a published build can lag behind it.

## Features

- **Source editor** with parser-based highlighting for Markdown, YAML frontmatter, fenced
  code, and JSX in `.mdx`. List continuation, auto-pairing, a table formatter, and
  checkbox toggling are built in.
- **Live preview** beside the editor, with scroll sync in both directions. GFM, KaTeX
  math, Mermaid diagrams, and code highlighting are bundled, so it works offline.
- **Files:** open one file or a folder workspace with a file tree (create, rename, move,
  move to Trash). Autosave, Save As, and a banner when the file changes on disk.
- **Find and Replace** in the document, and **workspace search** (⇧⌘F) across the folder.
- **Completion** for snippets, link and image paths, heading anchors, fence languages,
  frontmatter keys, emoji shortcodes, and MDX component names.
- **Images and links:** paste or drag an image to copy it into `assets/` and insert the
  link; paste a URL over selected text to make a link.
- **Frontmatter inspector** (⌃⌘I) with typed controls for dates, tags, and drafts.
- **Export** as self-contained HTML or PDF, and **Print** (⌘P).
- **Themes:** two built-in editor themes, imported JSON color themes, and system, light,
  and dark preview palettes.
- **Private by default:** sandboxed, no telemetry, and the preview loads nothing from the
  network unless you turn on **Allow remote images** in Settings.

Phase 2 WYSIWYG is still experimental. The inline fold/reveal mechanism and native interaction gates
exist behind an off-by-default **WYSIWYG mode (Experimental)** setting; source-only and source+preview
remain the default user-facing modes. To try it, enable **Settings ▸ Editor ▸ WYSIWYG mode
(Experimental)**, then cycle layouts from the **View** menu (`⌘⇧P`); it falls back to source-only if
the editor mechanism is unavailable, without altering source text. It stays off by default and is not
promoted to stable until [`docs/wysiwyg-release-checklist.md`](docs/wysiwyg-release-checklist.md) is
fully green. Inline-link folding and eligible local image thumbnails in folder workspaces are available
only inside that Experimental mode; reference links, autolinks, ineligible/single-file images,
fenced-code custom fragments, tables, Mermaid/math widgets, and real MDX rendering remain raw/deferred.

## Installing (alpha)

Download the latest DMG from [**GitHub Releases**](https://github.com/w3d-su/plainsong/releases)
and verify it with the attached `.sha256` (`shasum -a 256 -c Plainsong-*.dmg.sha256`).

Alpha builds are **unsigned** — there is no Apple Developer Program membership yet
(owner decision, 2026-07-02), so Gatekeeper blocks the first launch of a downloaded
build. Either:

- macOS: attempt to open the app once, then allow it via
  **System Settings ▸ Privacy & Security ▸ Open Anyway**, or
- Terminal: `xattr -d com.apple.quarantine /Applications/Plainsong.app`

Or skip Gatekeeper entirely by building from source (Xcode 16+):

```sh
make bootstrap && make build
```

Signed + notarized builds arrive when the release plan's P1/P2 resume
(see [`docs/release-engineering-plan.md`](docs/release-engineering-plan.md)).

## Development

Everything an agent or human needs to work on this codebase lives in
[`agent.md`](agent.md) — architecture, layering rules, milestone roadmap, and the
[Decision Log](docs/decision-log.md) (linked from §18). Read `agent.md` before writing code.

Useful planning and handoff docs:

- [`docs/m5-plan.md`](docs/m5-plan.md) — M5 acceptance history and Phase 2 entry sequence.
- [`docs/codex-handoff.md`](docs/codex-handoff.md) — Codex-ready goal/subagent prompts.
- [`docs/acceptance-matrix.md`](docs/acceptance-matrix.md) — milestone gates and evidence.
- [`docs/risk-register.md`](docs/risk-register.md) — current risks and mitigations.
- [`docs/wysiwyg-design.md`](docs/wysiwyg-design.md) — approved Phase 2 WYSIWYG spike design.

```sh
make bootstrap   # xcodegen, swiftformat, swiftlint, node + npm ci
make build       # generates Plainsong.xcodeproj and builds
make test        # Swift package tests + app tests + preview vitest suite
cd preview-src && npm run typecheck
```

Requires Xcode 16+ and macOS 14+.

## Math (KaTeX)

Inline `$…$` and display `$$` blocks (opening/closing `$$` on their own lines) render
with bundled KaTeX in both `.md` and `.mdx` previews; ` ```math ` fenced blocks render
the same way. Use `\$` for literal dollar signs; `\(…\)` and `\[…\]` delimiters are not
supported. Live fixture coverage: `Fixtures/math.md`.

## Known limitations (alpha)

- **Single-file mode and sibling images:** the sandbox grants access only to the file you
  opened, so relative `asset://` images next to it may not load. Open the containing folder
  as a workspace to grant directory scope.
- **MDX components render as placeholder cards** (imports as chips, JSX as component
  cards); components are not executed.
- **Preview images** are PNG/JPEG/GIF/WebP up to 10 MiB, plus workspace SVG up to 1 MiB
  shown only as an image after a structural check. `data:` SVG, inline `<svg>`, and SVG
  in HTML/PDF export are not supported. Remote images are off by default, and enabling
  them allows `https:` images only; a remote SVG is left to WebKit and is not validated.
- **Editor color themes** can be imported from Settings ▸ Editor. A theme is a JSON
  palette (`#RRGGBB` or `#RRGGBBAA` only; text, caret, and background must be opaque).
  Imported themes are listed separately from Plainsong and Graphite. The preview still
  uses the built-in system, light, and dark palettes. User CSS and per-slot fonts are
  not supported.
- **WYSIWYG is Experimental and inline-only** (headings, emphasis/strike, inline code,
  list/quote styling, inline `[text](url)` links, and thumbnails for local PNG/JPEG/GIF/WebP
  images up to 10 MiB in a folder workspace). Reference links, autolinks, remote/SVG/
  single-file images, tables, code fences, and Mermaid/math stay as raw Markdown in the
  editor; the preview pane renders everything.
- **Very large documents (about 1 MiB):** typing and scrolling work but are not instant.
  After each typing pause the preview re-renders only the blocks you changed; a document
  with link reference definitions or footnotes still re-renders whole.
- **Sidebar:** The sidebar is fixed-width on macOS 14–26. On macOS 27+ it is resizable
  (220–320 pt) and collapsible with ⌃⌘S.
- **Updates:** releases after `v0.1.0-alpha.5` can update in the app through Sparkle.
  alpha.1–alpha.5 have no updater, so install the next release by hand once. On the
  second launch Plainsong asks whether to check for updates automatically; **Plainsong ▸
  Check for Updates…** checks at any time. Automatic download and install is off by
  default (Settings ▸ General). A prerelease (a tag such as `v0.9.0-beta.1`) is offered
  only while **Receive beta updates** is on, so turn it on if you run beta builds. Builds
  are unsigned: macOS may ask you to confirm opening Plainsong again after an update.

## License

Copyright © 2026 w3d-su.

Plainsong is free software: you can redistribute it and/or modify it under the terms of the
[GNU General Public License](LICENSE) as published by the Free Software Foundation, either
version 3 of the License, or (at your option) any later version (SPDX: `GPL-3.0-or-later`).
It is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even
the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See
[`LICENSE`](LICENSE) for details.

The macOS editor links [STTextView](https://github.com/krzyzanowskim/STTextView) 2.4.1, which
its author offers to open-source applications under the GPLv3
([`docs/third-party/STTextView-2.4.1-LICENSE.md`](docs/third-party/STTextView-2.4.1-LICENSE.md)).
That is why Plainsong is GPL. Earlier versions, including every release through
`v0.1.0-alpha.5`, were published under the MIT License and remain available under it.

The App target also links [Sparkle](https://github.com/sparkle-project/Sparkle) 2.10.0.
Release builds set `PLAINSONG_UPDATES_ENABLED` to YES; other builds never create the
updater and make no update request. Every feed and download is verified against the EdDSA
public key in the app. Sparkle is MIT and bundles
bsdiff, sais-lite, and orlp/ed25519; those notices are in
[`docs/third-party/Sparkle-2.10.0-LICENSE.txt`](docs/third-party/Sparkle-2.10.0-LICENSE.txt).

Feedback and bug reports: [GitHub Issues](https://github.com/w3d-su/plainsong/issues).
The app collects no telemetry; alpha builds are distributed as direct downloads
(see [`docs/release-engineering-plan.md`](docs/release-engineering-plan.md)).
