# A WYSIWYG click hit-tests the laid-out viewport, not the whole document

Experimental WYSIWYG maps a click to a raw caret offset itself, because folded delimiters
lay out with zero width in a projected paragraph (wysiwyg-design §16). That mapping called
`ensureLayout(for: documentRange)` and then scanned every line fragment for the one
nearest the point. On `Fixtures/large-1mb.md` a click cost 0.1–1.5 s, and it also brought back
every paragraph element `EditorTextElementCacheTrimmer` had released, which slows the next
keystrokes until a trim runs again. Laying out the text above the viewport also replaced its
estimated heights with real ones, so in the middle of a large document the scan could pick a
different line than the one under the pointer.

`WYSIWYGPointerHitTest` now walks layout fragments from the TextKit viewport start to its end
only. STTextView 2.4.1 keeps the viewport at the visible area plus up to half a screen of
prefetch on either side, so it contains every point a click can reach. The walk stops at the
first line below the point that cannot be nearer. The rule is unchanged: nearest line by
vertical distance, first line on a tie, `.ensuresLayout` for invalidated viewport fragments.
If the visited lines do not enclose the point and the document continues past them, the
viewport is stale (a scroll or edit with no layout pass yet). The text view then runs its
pending layout once (`layoutSubtreeIfNeeded`, which the next display would run anyway) and
hit-tests again. Measurements: [`docs/perf/2026-10-24-wysiwyg-click-viewport-hit-test.md`](../perf/2026-10-24-wysiwyg-click-viewport-hit-test.md).

Also fixed in the same function: `NSTextLineFragment.characterIndex(for:)` counts from the
paragraph's start, like `characterRange`. The old mapping added the line's start again, so a
click on the second or later visual line of a wrapped paragraph put the caret at that line's
end, or at the start of the next paragraph. Every pointer-gate fixture is a single-line
paragraph, where the line's start is 0, so the gates never saw it.
`WYSIWYGWrappedLinePointerTests` covers it.

Alternatives: lay out pending changes before every click (rejected: STTextView's
`layout()` also runs a pending post-layout action such as scroll-to-selection, and
most clicks need no layout); keep walking past the viewport toward the point (rejected:
unbounded when the viewport is stale, and it recreates trimmed elements); start from
TextKit's point lookup `textLayoutFragment(for:)` (not needed: it returns the fragment that
contains the point, so a point between lines or beside the text still needs the nearest-line
walk, and the viewport already bounds that walk); fall back to STTextView's native
`mouseDown` hit-test whenever the viewport is stale (rejected: that path does not snap carets
out of folded delimiters, checklist C.2).
