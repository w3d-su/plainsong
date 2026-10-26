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
vertical distance, first line on a tie. The walk lays nothing out. It enumerates without
`.ensuresLayout`, because that option lays out the next fragment before the block can see that
it lies past the viewport end. It stops at the viewport end or at a fragment without layout.
Measurements: [`docs/perf/2026-10-24-wysiwyg-click-viewport-hit-test.md`](../perf/2026-10-24-wysiwyg-click-viewport-hit-test.md).

If the visited lines do not enclose the point and the document continues past them, the
viewport is stale: a scroll or edit with no layout pass yet. The hit-test then has TextKit lay
out a band three default line heights above and below the point (`ensureLayout(for: CGRect)`).
It finds the band's first fragment by position and applies the same rule to the fragments in
the band, again without laying anything out during the walk. When the point lies inside the
viewport that the next layout pass will lay out (STTextView's `viewportBounds(for:)`, which
only reads the visible rect), the layout starts at that viewport's top edge instead. That pass
places its top edge by TextKit's height estimate of the text above and lays out downward. Laid
out from the band's own top, the estimate for the text in between could put the band's lines
a line or more from where that pass draws them. That happened to all three stale clicks per
probe round on `large-1mb.md` (44–120 characters off) and to
`testClickInTextNeverLaidOutLandsWhereTheNextLayoutPassDrawsIt`. If the band's lines do not
enclose the point either, the click goes to STTextView's native `mouseDown` rather than to a
wrong line.

No view layout runs inside `mouseDown`. STTextView's `layout()` also runs a pending
post-layout action: a scroll to the selection, which Select Word, Select Line, moving by line
and every text change leave behind.

TextKit's position lookups behind the band scan the fragment frames above the point, though
they lay out and create only the paragraphs of the rect they are given. In a debug build at
60,000 lines (load ~150), `ensureLayout(for: CGRect)` cost ~11 ms and
`textLayoutFragment(for: CGPoint)` ~20 ms, against 0.07 ms for a 40-fragment viewport walk.
Laying out a band after a stale scroll over released elements created 7 paragraph elements,
the band's own. STTextView's native click lookup (`caretLocation(interactingAt:)`) costs the
same ~20 ms once the viewport is stale. That is why the band is the fallback, not the only
path. In a release build on `large-1mb.md` a stale click's median was 1.3–15 ms (worst 24 ms),
growing with the text above the point; the first version's view layout cost 12–40 ms there.

Also fixed in the same function: `NSTextLineFragment.characterIndex(for:)` counts from the
paragraph's start, like `characterRange`. The old mapping added the line's start again, so a
click on the second or later visual line of a wrapped paragraph put the caret at that line's
end, or at the start of the next paragraph. Every pointer-gate fixture is a single-line
paragraph, where the line's start is 0, so the gates never saw it.
`WYSIWYGWrappedLinePointerTests` covers it.

Alternatives:

- Lay out pending changes before every click. Rejected: STTextView's `layout()` also runs the
  pending post-layout action, and most clicks need no layout.
- Run the view's pending layout (`layoutSubtreeIfNeeded`) only when the viewport is stale.
  This was the first version of this change; review rejected it. The pending post-layout
  action could scroll back to the old selection mid-click, and the caret then landed on a
  line near that selection, not on the clicked text. And with `needsLayout == false` it
  returned the viewport's edge line as the hit. STTextView records a layout request made during its
  viewport pass in a private flag only, so a stale viewport can come with that state.
- Lay out the band around every click (the review's preferred approach). Rejected: TextKit's
  position lookups grow with the text above the point, about 30 ms per click at 60,000 lines
  in a debug build. The viewport walk does not.
- Keep walking past the viewport toward the point. Rejected: unbounded when the viewport is
  stale, and it recreates trimmed elements.
- Start every click from TextKit's point lookup `textLayoutFragment(for:)`. Rejected: it
  returns only the fragment that contains the point, so a point between lines or beside the
  text still needs the nearest-line walk, and it scans the frames above the point. The band
  uses it only on the stale path.
- Fall back to STTextView's native `mouseDown` whenever the viewport is stale. Rejected: that
  path does not snap carets out of folded delimiters (checklist C.2). It remains the fallback
  only when even the band does not enclose the point.
