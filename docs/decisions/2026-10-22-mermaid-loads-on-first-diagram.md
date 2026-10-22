# Mermaid ships as a separate script loaded on the first diagram; only woff2 KaTeX fonts ship

Every preview WebView (the live pane, and each HTML/PDF/print export WebView) parsed the
whole 4.05 MB `bundle.js` at start-up, and Mermaid with its dependencies (cytoscape,
`@mermaid-js/parser`, d3, dagre, …) was 3.2 MB of it per an esbuild metafile, although most
blog posts have no diagram. Evaluating the bundle in jsdom took about 110 ms against about
30 ms without Mermaid (three runs each, Node/V8; WebKit numbers differ but parse/compile
cost scales with size). `build.mjs` now emits `bundle.js` (797 KB) and `mermaid.js`
(3.46 MB); `LazyMermaid` in `src/mermaid-loader.ts` injects `mermaid.js` with a classic
`<script>` on the first `mermaid.render`, applies the latest theme configuration when it
loads, and lets a failed load surface as `.mermaid-error` that the next render retries.
`mermaid.js` carries its own copy of the pieces it shares with the main bundle (KaTeX among
them), so the two files together are slightly larger than the old single file; the cost is
paid only by documents with diagrams.

The same PR stops shipping KaTeX's woff and ttf fonts (876 KB). WebKit always takes the
woff2 source and static export embeds only woff2 (`ExportFontManifest`), so the build drops
the fallbacks from KaTeX's CSS and fails if KaTeX's CSS stops matching that shape. It also
aliases `acorn` to its ESM build: `micromark-extension-mdxjs` imports `acorn.mjs` while
`acorn-jsx` requires `acorn.js`, which bundled both copies (about 120 KB).

Alternatives: esbuild code splitting with `format: "esm"` (rejected: the preview is loaded
from a file: URL, where module scripts are subject to CORS, and Mermaid's own dynamic
imports would become many chunk files); keeping one bundle and relying on JavaScriptCore's
lazy function parsing (rejected: top-level module initialization of Mermaid and its
dependencies still runs on every load, and the source is still pre-parsed); loading
Mermaid from a CDN (rejected: the app must work offline and the CSP forbids it); sharing
KaTeX between the two scripts through a global (rejected: couples the bundles for a
saving that only diagram documents would see).
