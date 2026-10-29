# Serve workspace SVG as an image, unchanged

**Date:** 2026-10-29
**Status:** Accepted for preview image mode. Export embedding is not part of this decision.

## Decision

Workspace `.svg` files may be shown in the preview, but only as images (`img` sourced from
`asset://`). `SVGImageValidator` in MarkdownCore accepts or rejects the original bytes.
It does not rewrite them. An admitted file is at most 1 MiB of valid UTF-8 (an XML
declaration may only declare `UTF-8`), has a root element named exactly `svg` in the SVG
namespace, and contains no DOCTYPE, script, foreign content (`foreignObject`, `iframe`,
`object`, `embed`, `handler`, `listener`), event-handler attributes, external `href` /
`xlink:href` / `src`, SMIL animation of those references, processing instructions, or
CSS `@import`, `image-set(`, `cross-fade(`, `src(` or `url(` other than a same-document
`url(#id)`. CSS escapes are decoded before that scan (`u\72l(` is `url(`), so escaped
CJK font names stay admitted. A `<style>` element holds text only: any child element,
a nested `<style>` included, rejects. The same CSS rule applies to the CSS-valued
presentation attributes already treated as URL sinks by export (`fill`, `stroke`,
`clip-path`, `filter`, `mask`, markers, `cursor`, `style`), because
`fill="url(https://…)"` is the same load as a `style` attribute, and to the SMIL value
attributes `from`, `to`, `by` and `values`. Caps are 50,000 elements and depth 256.

PreviewKit serves the admitted bytes with `Content-Type: image/svg+xml; charset=utf-8`,
`X-Content-Type-Options: nosniff` and `Content-Security-Policy: default-src 'none';
style-src 'unsafe-inline'`. If that header response cannot be built, the request fails;
an SVG is never served without it. The charset pins WebKit to UTF-8 (the HTTP charset
overrides the XML declaration), and the declaration rule pins `XMLParser` to it, so both
see the same characters. Validation runs off the main actor. Path containment is
unchanged. The reader's coordinated file and the requested file must agree on being SVG,
since one chose the byte cap and the other chooses the validator. The Mac reader opens
an SVG without blocking, requires a regular file, and reads at most one byte past the cap.

The response CSP is a backstop for document mode, not the image-mode barrier. WebKit
builds an SVG image from the bytes, and the S0 probe shows the isolation without that
header: it serves fourteen well-formed, painted hostile samples (script, `onload`,
`foreignObject`, `<image href>`, `<use href>`, `@import`, `url(https:)` in style, an
escaped `url(`, `image-set`, `@font-face`, `feImage`, a `fill` URL, a SMIL `values` URL,
and the rejected-but-paintable end-to-end control) with no validator and no CSP,
and records zero bridge messages and zero proxy connections, while a page script and a
page image prove both observers work. Document mode is already closed by the navigation
policy and the page CSP (`default-src 'none'`).

`data:image/svg+xml` and inline `<svg>` stay blocked. HTML/PDF export still omits SVG
(`AssetURLPolicy.loadAsset` remains the raster export gate). WYSIWYG does not thumbnail
SVG. Remote `https:` SVG is not specially blocked or validated (owner decision pending).
With Allow Remote Images off it is never requested; with it on, the S0 remote probe saw
four `CONNECT` requests to the remote host and no successful decode. It would render in
the same image mode as any remote image. Filtering by `.svg` would not help (`a.png` can
answer `image/svg+xml`); a real control is a separate gate that proxies remote images
through a native scheme, checks the MIME type, and validates or rejects SVG.

## Why

Blog folders routinely contain SVG diagrams and icons. Rejecting every SVG left them
broken in the preview. Image mode, plus an accept/reject structural check, covers script,
external loads, XXE, and huge documents without a sanitizer that could diverge from the
file the user saved.

## Alternatives considered

- Sanitize and inline the SVG. Rejected: the SVG would run in the preview origin, and
  the served markup would no longer be the file.
- Rasterize to PNG. Rejected: another renderer, softer edges, and extra latency.
- Trust WebKit image mode with no validator. Rejected: one engine bug would be the only
  barrier, and DOCTYPE expansion would still happen in our parser if we were careless.
- Keep rejecting SVG. Rejected for workspace images; still the rule for `data:`, inline
  markup, and export until those gates are designed.
