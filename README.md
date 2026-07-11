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
live MDX completion-popup checklist blockers; `docs/m5-checklist.md` now passes.

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
Decision Log. Read it before writing code.

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

## Known limitations (alpha)

- **Single-file mode and sibling images:** the sandbox grants access only to the file you
  opened, so relative `asset://` images next to it may not load. Open the containing folder
  as a workspace to grant directory scope.
- **MDX components render as placeholder cards** (imports as chips, JSX as component
  cards); components are not executed.
- **Preview images** are limited to PNG/JPEG/GIF/WebP up to 10 MiB; SVG is not rendered.
  Remote images are off by default, and enabling them allows `https:` images only.
- **WYSIWYG is Experimental and inline-only** (headings, emphasis/strike, inline code,
  list/quote styling). Links, images, tables, and code fences stay as raw Markdown in the
  editor; the preview pane renders everything.
- **The sidebar is fixed-width** for now.
- **No auto-update:** alpha builds are manual downloads.

## License

Plainsong is open source under the [MIT License](LICENSE).

Feedback and bug reports: [GitHub Issues](https://github.com/w3d-su/plainsong/issues).
The app collects no telemetry; alpha builds are distributed as direct downloads
(see [`docs/release-engineering-plan.md`](docs/release-engineering-plan.md)).
