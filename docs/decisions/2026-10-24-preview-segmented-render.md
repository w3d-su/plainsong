# The preview renders a document as cached segments whose HTML equals a whole render

Every preview update ran the whole unified pipeline over the whole document. In WebKit
the parse alone took ~70% of an edit on `Fixtures/large-1mb.md` (~0.9-1.0 s of
~1.2-1.5 s at load ~90); stringify, mdast-to-hast and KaTeX's tree walk took most of the
rest of the pipeline. Measurements: `docs/perf/2026-10-24-preview-segmented-render.md`.

`SegmentedRenderer` (`preview-src/src/segmented-render.ts`) cuts the text into segments,
renders each through the same plugins in segment mode, and keeps each segment's HTML for
the next render. An edit re-renders the one or two segments it touches. The joined result
is the exact string `renderMarkdown`/`renderMdx` returns; the DOM path after it (inert
parse, image rewrite, Mermaid placeholders, morphdom, highlight) is unchanged.

Cuts. A cut may go before a line that follows a blank line, starts in column 1, and does
not start with `-`, `+`, `*`, an ordered-list marker (`1.`, `1)`) or a BOM, and lies after
any frontmatter (including frontmatter after one leading BOM, which micromark skips). These
rules keep a list from continuing across the cut, keep a cut out of frontmatter, and keep a
segment from starting with frontmatter. The segment before a cut is parsed with a sentinel
paragraph appended on the line where the next segment starts. If the sentinel does not
come back as a top-level paragraph of its own on that line, a construct was still open: a
fence, `$$` math, an HTML block of kinds 1-5, MDX JSX, an expression or ESM. The cut is
then rejected and the segment grows to a later cut. An MDX parse error in a segment before
the last cut rejects the cut the same way. After four rejected cuts from one segment start,
the rest of the document is one segment. The parse with the sentinel also gives a list or
any other last block exactly the context that a following column-1 line gives it in the
whole document.

Segments are about 2-4 KB: a cut becomes a segment end once the segment holds 2 KiB and the
FNV-1a hash of the cut line's first 64 UTF-16 units is divisible by 4, or once it holds
16 KiB. Choosing by local content keeps the cuts after an edit where they were, so later
segments keep their cache keys. The 1 MiB fixture has 324 segments. The cache holds the
segments of the previous render only.

Document-wide values become holes in segment mode: `data-line` and `data-line-end`
(segment-relative lines), `data-math-index` (a counter over the whole document) and
generated heading IDs (deduplicated against every earlier heading). The plugins write a
`U+0000` marker there; micromark replaces `U+0000` in its input, so markers cannot collide
with document text, and the stringifier escapes them as `&#x0;`. Assembly adds the
segment's start line and the earlier math count, and allocates heading IDs in order with
the same allocator as the whole render. A user-written `data-line` on a non-block MDX
element stays literal, as it does in the whole render.

Whole renders. These cases render the whole document, as before:

- A link reference or footnote definition anywhere, because it resolves references in
  every segment.
- A KaTeX message whose formula cannot be located. Orphan messages pair with errors
  anywhere in the document.
- An MDX ESM block in a segment after one that imports a binding.
  micromark-extension-mdxjs-esm parses each block after `var <earlier imports>`, so a
  repeated import fails and `export { X }` needs an earlier import.
- A lone CR line ending.
- A document whose only segment is the whole text, including any document under 2 KiB.
- A parse error in the last segment, so the MDX error banner keeps the whole render's
  error and line.
After #220, both whole and segmented processors use `remarkClosedFrontmatter`. An
unclosed leading `---` renders as a thematic break and no longer requires a whole render.
Closed frontmatter remains protected from cuts, including after a leading BOM.

`test/segmented-render.test.ts` compares segmented and whole output, string for string,
over random documents and random edits for both pipelines. Two cut settings are used:
every legal cut, and sparse cuts. `PLAINSONG_SEGMENT_SOAK=20` ran 46,080 comparisons
locally, about 20,000 of them segmented. The test asserts that a minimum share of renders
actually segment, so that it cannot pass by always falling back to a whole render.
`test/segmented-preview.test.ts` drives the bridge: after edits that shift lines and repeat
a heading, the preview equals one render of the final text, and checkbox writeback reports
the task's new line.

Alternatives:
- Incremental parsing only, reusing mdast subtrees. Rejected: stringify, mdast-to-hast and
  the rehype walks stay O(document), about a third of the pipeline.
- Caching per top-level block of the previous parse. Rejected: the previous tree cannot
  show whether the edited text closes or opens a construct that spans the cut, and the
  sentinel check can.
- Fixed-size chunks. Rejected: one inserted character would move every later boundary and
  miss the cache.
- Pre-rendering definitions into every segment. Deferred: definitions would have to be
  re-serialized exactly; footnotes number and collect globally.
- Patching the DOM per segment instead of morphdom over the whole root. Deferred: it is the
  next cost (see the perf entry), but it needs its own equivalence rules for preserved
  highlight, Mermaid, image and checkbox state.
