# EditorKit draws line numbers; STTextView's gutter stays off

STTextView 2.4.1's gutter was the largest remaining main-thread cost when typing in large
documents (#180, "Known limits"). On every layout pass it removed and recreated one
`NSView` per visible line and counted every paragraph above the viewport with
`textElements(for:)`. In a release-optimized EditorKit harness on `large-1mb.md`
(900 x 800 pt) a keystroke's layout took about 1 ms with line numbers off and 10.5, 11.7
and 13.5 ms with them on and the caret at 5%, 50% and 95% of the document: mostly the view
churn, plus the count above the viewport. EditorKit now keeps `showsLineNumbers` off and
owns the gutter:

- `EditorLineNumberGutterView` only draws. Each draw walks the layout fragments of the
  TextKit viewport that intersect its dirty rect and numbers each one with a binary search
  in `EditorScrollLineIndex`. Nothing per layout or keystroke depends on the document
  length or the text above the viewport, and the view never lays out or invalidates layout.
- The line index moved from the scroll-sync attachment into `EditorLineIndexCache`, one per
  text view, which the coordinator edits in place from `willChangeTextIn`. Scroll sync and
  the gutter share it, so line numbers follow scroll sync and the preview: only `\n` starts
  a line. A paragraph TextKit starts after a lone `\r` or U+2029 gets no number.
- `EditorScrollView` (from `MarkdownSTTextView.scrollableTextView()`) tiles the gutter left
  of the clip view, so STTextView wraps text to the visible width without a gutter inset.
  `super.tile()` first gives the clip view its full width; STTextView autoresizes with the
  clip view, so the override passes on only the net change instead of re-laying out the
  text container twice per retile.
- A number sits on the text baseline of its source line's first visual line, as in code
  editors. Wrapped continuation lines get none; the empty line after a final newline does.
  STTextView centered the number on the first line instead: for body text the two differ
  by about a point, but on taller lines (scaled headings, WYSIWYG image thumbnails, whose
  baseline is the thumbnail's bottom edge) the baseline keeps one rule for every line.
- The width is sized for the document's line count (at least 3 digits). It grows at once
  but shrinks only below 90% of the narrower width's limit, so typing around 999/1000 lines
  does not re-wrap the document, and it never changes while marked text is composed.
- Colors follow the editor theme (`mutedColor`, `textColor` for the caret's line) and are
  resolved at draw time for the current appearance. The current-line band uses STTextView's
  `selectedLineHighlightColor`, as before. The gutter has no background of its own unless
  the text view sets one; STTextView's drew a `.contentBackground` visual-effect view.

Alternatives: an upstream STTextView change (not available on our pinned version, and the
cost is in private API); STTextView's `gutterView` with a custom view (rejected: STTextView
still runs the per-line layout whenever a gutter view exists); an `NSRulerView` as the scroll
view's vertical ruler (tried first; on current macOS rulers float over the clip view as a
left content inset, which STTextView 2.4.1 does not subtract from its width, so the text
view stayed 35 pt wider than the visible area and could scroll sideways); one `NSView` per
visible line numbered from the line index (rejected: the view churn was most of STTextView's
cost); centering numbers on the first line like STTextView (rejected: no text-based
reference on tall lines, and the baseline is what the number labels).
