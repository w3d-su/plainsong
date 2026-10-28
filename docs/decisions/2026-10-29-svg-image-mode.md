# Serve workspace SVG as an image, unchanged

**Date:** 2026-10-29
**Status:** Accepted for preview image mode. Export embedding is not part of this decision.

## Decision

Workspace `.svg` files may be shown in the preview, but only as images (`img` sourced from
`asset://`). `SVGImageValidator` in MarkdownCore accepts or rejects the original bytes.
It does not rewrite them. An admitted file is at most 1 MiB of UTF-8, has an `svg` root
in the SVG namespace, and contains no DOCTYPE, script, foreign content (`foreignObject`,
`iframe`, `object`, `embed`, `handler`, `listener`), event-handler attributes, external
`href` / `xlink:href` / `src`, SMIL animation of those references, processing
instructions, or CSS `@import` / `url(` other than a same-document `url(#id)`. The same
`url(` rule applies to the CSS-valued presentation attributes already treated as URL
sinks by export (`fill`, `stroke`, `clip-path`, `filter`, `mask`, markers, `cursor`),
because `fill="url(https://…)"` is the same load as a `style` attribute. Caps are 50,000
elements and depth 256.

PreviewKit serves the admitted bytes with `Content-Type: image/svg+xml` and
`Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'`. Validation runs
off the main actor. Path containment is unchanged.

`data:image/svg+xml` and inline `<svg>` stay blocked. HTML/PDF export still omits SVG
(`AssetURLPolicy.loadAsset` remains the raster export gate). WYSIWYG does not thumbnail
SVG. Remote `https:` SVG is not specially blocked or validated; S0 records whether
WebKit requests it when Allow Remote Images is on.

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
