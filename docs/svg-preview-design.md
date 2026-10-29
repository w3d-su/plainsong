# SVG Images in Preview and Export — Design Draft

> **Status: PR B implemented (2026-10-29); PR C (export) not started.** Workspace SVG is
> shown in the preview in image mode after `SVGImageValidator`
> ([decision](decisions/2026-10-29-svg-image-mode.md), agent.md §7.1). The current
> rules live in that decision; this document keeps the design rationale. Export still
> omits SVG.

## 1. Problem

Blog content folders routinely hold SVG diagrams, logos and icons. Plainsong shows them as
broken images, and HTML/PDF export omits them. The README lists this as a known
limitation. SVG was rejected in M5 because it is an active document format, not because
it was hard to display.

## 2. Current state (code verified)

SVG is refused at four independent points; each must change deliberately:

| Point | Where | Today |
|---|---|---|
| `asset://` serving | `AssetURLPolicy.mimeType(for:)` → `MarkdownImageAssetPolicy` (`Packages/PreviewKit/Sources/PreviewKit/AssetURLSchemeHandler.swift`, `Packages/MarkdownCore/Sources/MarkdownCore/MarkdownImageRegions.swift`) | PNG/JPEG/GIF/WebP only, ≤ 10 MiB |
| `data:` images in Markdown | `allowedDataImageMediaTypes` in `preview-src/src/image-policy.ts` | raster media types only |
| Inline `<svg>` in Markdown/MDX HTML | `sourceSvgTags` in `preview-src/src/pipeline.ts` | dropped by the sanitizer |
| Export embedding | `ExportRasterSniffer` (ImageIO decode, raster UTTypes only) | omitted with a typed outcome |

Two facts already in place make an image-only design tractable:

- `PreviewController.navigationPolicy(for:previewIndexURL:)` allows only the bundled
  `index.html`; every other navigation, including `asset://…`, is cancelled. An SVG can
  therefore never become a top-level or frame document in the preview.
- Mermaid output is generated, trusted SVG inserted into the DOM. It is unrelated to
  user SVG and keeps its own path (§7.2).

To verify in S0: with Allow Remote Images on, an `https:` URL whose server answers
`image/svg+xml` is probably already rendered by WebKit today, in image mode, because the
JS policy filters by scheme rather than by media type.

## 3. Threat model

An SVG file from a cloned repository or a downloaded theme may contain:

1. Script: `<script>`, `on*` attributes, `javascript:` URLs, SMIL `<set>`/`<animate>` on
   `href`.
2. Embedded HTML: `<foreignObject>`.
3. External references: `href`/`xlink:href` to `http(s):`/`file:`, `<use>` of external
   documents, CSS `@import` and `url(...)`, `<image>` loading remote content (tracking).
4. XML attacks: `<!DOCTYPE>` with internal/external entities (entity expansion, XXE).
5. Resource exhaustion: millions of nodes, deep nesting, heavy filters or patterns.
6. Spoofing: an image that looks like Plainsong UI (error banner, stale indicator).

## 4. Proposed design

### 4.1 Image mode only (core rule)

User SVG is admitted **only as an image resource** — `![](x.svg)`, `<img src="x.svg">`,
and the same in MDX. It is never parsed into the preview DOM, never inlined, and never
loaded as a document. WebKit renders SVG-as-image in a restricted mode: no script, no
event handling, and no external resource loads. Threats 1–3 are then handled by the
engine; this design adds defense in depth around it and handles 4–5 itself. Inline
`<svg>` stays dropped by the sanitizer (unchanged).

Spoofing (6) is accepted: any raster image can show the same pixels.

### 4.2 Swift-side structural validator (accept/reject, never rewrite)

Before `asset://` serves an `.svg`, a pure validator in MarkdownCore (no UI imports)
checks the original bytes, off the main actor:

- UTF-8, ≤ **1 MiB** [owner: proposed SVG-specific cap, below the 10 MiB raster cap].
- Parsed with `XMLParser` with external entity resolution disabled. **Any `<!DOCTYPE>`
  rejects** (no entity handling at all).
- Root element is `svg` in the SVG namespace.
- Rejects: `script`, `foreignObject`, `iframe`, `object`, `embed`, `handler`,
  `listener`; any attribute named `on*`; any `href`/`xlink:href`/`src` that is not a
  same-document fragment (`#id`); `<style>` text or `style` attributes containing
  `@import` or `url(` other than `url(#id)`; SMIL elements targeting `href`.
- Caps: ≤ 50,000 elements and depth ≤ 256 [owner: initial numbers, tuned by S6].

Accepted files are served **byte-for-byte unchanged** with `Content-Type:
image/svg+xml; charset=utf-8`, `X-Content-Type-Options: nosniff`, and a response CSP
of `default-src 'none'; style-src 'unsafe-inline'`. The response CSP is a document-mode
backstop; WebKit image-mode isolation is verified separately without that header.
Rejected files fail like an unsupported image today. The validator's reason is kept
in process (`AssetURLPolicyError.rejectedSVG`) and logged without file paths; showing it
in the preview is not built yet. Delivery details are recorded in
[`2026-10-29-svg-image-mode.md`](decisions/2026-10-29-svg-image-mode.md).

Accept/reject keeps the served bytes auditable: there is no sanitized output that could
differ from what the user sees in the source, and no mutation-XSS class of bugs.

### 4.3 Sources

| Source | v1 proposal |
|---|---|
| Workspace `asset://` `.svg` | **Allowed** after §4.2 |
| `data:image/svg+xml` in the document | **Blocked** [owner]: would need a second validator in JS |
| Remote `https:` SVG (Allow Remote Images on) | Unchanged from today: WebKit image mode, no validator (S0 records what actually happens) |
| Single-file mode sibling SVG | Same limitation as raster siblings (no directory grant) |

### 4.4 Export

HTML export embeds a validated SVG as `data:image/svg+xml;base64,…` in an `<img>`,
after the same validator runs on the bytes read for export (not a cached verdict). This
needs a new `ExportRasterSniffer` sibling, since ImageIO cannot decode SVG. Embedded SVG
counts toward the R19 aggregate caps like any raster. PDF/Print use the same finalized
DOM, so they inherit the result. Export CSP already allows `data:` images.

### 4.5 Out of scope for v1

- Experimental WYSIWYG thumbnails of SVG (stays raw; NSImage SVG behavior unverified).
- Inline `<svg>` in Markdown/MDX.
- Rewriting/sanitizing SVG content (DOMPurify or similar).
- Image path completion changes (verify whether `.svg` is already listed; align it with
  the preview either way).

## 5. Alternatives considered

| Alternative | Why not |
|---|---|
| Sanitize with DOMPurify and inline into the DOM | Inline SVG runs in the preview document's origin; sanitizer bypasses become preview XSS. Output differs from the file. |
| Rasterize SVG in Swift (WebKit snapshot or a renderer) and serve PNG | Extra web view or new dependency, loses crispness, adds latency per image |
| Engine image mode with no validator | Relies on one WebKit guarantee only; no XXE or size defense; an engine bug becomes a direct exposure |
| Keep rejecting SVG | Leaves a common blog asset broken in preview and export |

## 6. Gates

| Gate | Evidence |
|---|---|
| **S0 mechanism probe** | In the production `WKWebView` configuration on macOS 14 and 27: SVG images containing script, `onload`, `<foreignObject>`, `<image href="https://…">`, CSS `@import`/`url(https:…)` and `<use href="https:…">` produce zero script execution (bridge never receives a probe message) and zero network requests (served through a counting scheme handler and a local HTTPS stub). Also records today's remote-SVG behavior (§2). |
| **S1 validator matrix** | MarkdownCore table tests: each §4.2 rule accepts and rejects; DOCTYPE/entity bombs; non-UTF-8; caps at boundary; real-world fixtures (Inkscape, Figma, Illustrator exports) accepted. |
| **S2 asset serving** | Handler serves unchanged bytes, MIME, response CSP; path containment, symlink and `..` tests still pass; asset-root token rules unchanged. |
| **S3 JS policy** | `image-policy.ts` vitest: `.svg` asset URLs rewrite like raster; `data:image/svg+xml` stays blocked; inline `<svg>` still dropped. |
| **S4 navigation** | Hosted test: clicking a link to `x.svg` and script-free navigation attempts to `asset://x.svg` are cancelled by the existing policy. |
| **S5 export** | HTML export embeds a valid SVG and omits a rejected one with a typed outcome; PDF shows it; R19 cap tests include SVG. |
| **S6 resource bounds** | Largest accepted SVG (caps) renders within the §12 preview budget; WebContent memory recorded in `docs/perf/`. |
| **S7 regressions** | Preview, MDX sanitizer, asset and export suites green; `PROTOCOL_VERSION` unchanged (no bridge change expected). |
| **S8 docs** | agent.md §7.1, README limitations, R4/R5 updated; Decision Log entry. |

## 7. PR plan

- **A** — this spec (docs only).
- **B** — S0 probe + validator (MarkdownCore) + asset serving + JS policy: S0–S4, S7.
- **C** — export embedding: S5, S6, S8.

## 8. Owner decisions

- Decided in PR B: SVG byte cap 1 MiB, 50,000 elements, depth 256 (S6 may still tune
  them); `data:image/svg+xml` stays blocked in v1.
- Pending: remote `https:` SVG. Recommended for v1: leave it unblocked and documented
  (remote images are opt-in and render in the same image mode). The macOS 27 probe saw
  four `CONNECT`s and no successful decode; macOS 15.7.9 CI saw one `CONNECT`.
  An `.svg` extension filter would not work;
  a real control is a separate gate that proxies remote images through a native scheme
  and validates or rejects SVG by MIME type.
