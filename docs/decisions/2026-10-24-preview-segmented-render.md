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
any frontmatter. These rules keep a list from continuing across the cut, keep a cut out of
frontmatter, and keep a segment from starting with frontmatter. Where frontmatter ends comes
from `closedFrontmatterEnd` in `frontmatter.ts`, the same rule `remarkClosedFrontmatter`
(#220) uses to enable frontmatter for the text it parses: an opening `---` at the start,
after at most one BOM, read only when a closing fence follows. The first segment therefore
holds the closing fence and reads the frontmatter as the whole document does. Later segments
never start with `-` or a BOM, so they read none, even when they contain `---` rules. An
unclosed opener is a thematic break in both renders and is cut like any other document.
The segment before a cut is parsed with a sentinel
paragraph appended on the line where the next segment starts. If the sentinel does not
come back as a top-level paragraph of its own on that line, a construct was still open: a
fence, `$$` math, an HTML block of kinds 1-5, MDX JSX, an expression or ESM. The cut is
then rejected and the segment grows to a later cut. An MDX parse error placed on the
sentinel's line or later, or with no place (an unclosed element), rejects the cut the same
way; one placed before it is an error in the segment, and the document renders whole.
The parse with the sentinel also gives a list or any other last block exactly the context
that a following column-1 line gives it in the whole document.

Retries (`segment-closers.ts`). A rejected cut says how the open construct ends when that
can be found by text: a closing fence of at least the opening length for code and math,
the end condition of HTML kinds 1-5, or the closing tag of an unclosed MDX element. The
next try from the same start skips to the line after that close, and in any case waits
until the segment is twice as long (`retryGrowth`), so the tries from one start cost at
most about twice the segment they end with. A fence, math or HTML block that never closes
makes the rest of the document one segment; an MDX element that never closes cannot parse,
so the document renders whole. A rejection with no known end stops trying once a try would
hold more than half of the rest. A prediction never decides output: the next cut is still
checked with the sentinel. Without this, the PR's first version stopped after four
rejected cuts and made the rest one segment, so one fence with blank lines between its
functions, or an MDX element wrapping sections, early in a post disabled the cache for
everything after it (or, before any accepted cut, for the whole document).

Segments are about 2-4 KB: a cut becomes a segment end once the segment holds 2 KiB and the
FNV-1a hash of the cut line's first 64 UTF-16 units is divisible by 4, or once it holds
16 KiB. Choosing by local content keeps the cuts after an edit where they were, so later
segments keep their cache keys. The 1 MiB fixture has 324 segments. The cache holds the
segments of the previous segmented render only, keyed by segment text: a segment before a
cut is parsed with the sentinel on the line after its text, so its text fixes its outcome,
and last segments are kept in a map of their own. The preview keeps one renderer, for the
file kind it last rendered, so a change of kind does not keep the other kind's last
document in memory.

Document-wide values become holes in segment mode: `data-line` and `data-line-end`
(segment-relative lines), `data-math-index` (a counter over the whole document) and
generated heading IDs (deduplicated against every earlier heading). The plugins write a
`U+0000` marker there; micromark replaces `U+0000` in its input, so markers cannot collide
with document text, and the stringifier escapes them as `&#x0;`. Assembly adds the
segment's start line and the earlier math count, and allocates heading IDs in order with
the same allocator as the whole render. A user-written `data-line` on a non-block MDX
element stays literal, as it does in the whole render. The whole render joins the root's
nodes with newlines before the MDX pipeline drops script-like, source SVG and sanitized
elements, so a segment records whether it had any root node, and assembly joins it even
when nothing of it reached the HTML.

ESM. micromark-extension-mdxjs-esm parses each ESM block after `var <imports of earlier
blocks>`, so a repeated import fails and `export { X }` needs an earlier import. A segment
whose ESM follows a segment that imports a binding (or whose ESM fails to parse alone) is
merged with every segment from the importing one, which parses with the same imports as
the whole document. The merged segment is cached like any other.

Whole renders. These cases render the whole document, as before:

- A link reference or footnote definition anywhere, because it resolves references in
  every segment.
- A KaTeX message whose formula cannot be located. Orphan messages pair with errors
  anywhere in the document.
- A lone CR line ending.
- A document whose only segment is the whole text, including any document under 2 KiB.
- A document that does not parse, so the MDX error banner keeps the whole render's error
  and line.

The whole render reports whether the document has a definition or an orphan KaTeX
message. While it does, renders stay whole without a segment pass, except that a text
without the definition-like lines that showed the definitions (another document, or the
lines deleted) segments at once. A document that does not parse also renders whole,
without a segment pass, until a whole render succeeds.
Segmenting then resumes with the cache of the last segmented render. A segment pass would
find a definition only at its segment, after rendering every segment before it, so lines
that look like a definition (`[label]:` after indentation, block quote and list markers)
send the first render that sees them to a whole render that checks. Definitions are often
at the end of a post, where the first version paid a full segment pass on every open and
an extra segment render on every edit before rendering whole.

`test/segmented-render.test.ts` compares segmented and whole output, string for string,
over random documents and random edits for both pipelines. Two cut settings are used:
every legal cut, and sparse cuts. `PLAINSONG_SEGMENT_SOAK=20` ran 46,080 comparisons
locally, about 20,000 of them segmented. The test asserts that a minimum share of the
renders of parsing documents actually segment, so that it cannot pass by always falling
back to a whole render. The random MDX blocks include elements the pipeline drops.
`test/segmented-render-fallbacks.test.ts` covers the review follow-up: dropped-only MDX
segments, cutting resumed after a long fence, HTML comment or MDX element, a fence left
open, definitions and definition-like lines, ESM merging, and MDX errors.
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
