# Scroll sync reports the line at the visible top edge, not the TextKit viewport start

STTextView 2.4.1 (#180) returns viewport bounds that extend up to half the visible height
above the visible area, so TextKit's `viewportRange.location` is text the user cannot see.
`EditorScrollAttachment.firstVisibleLine()` and `reportVisibleRangeIfNeeded` sent that
location to the preview as the top line, so after any scroll the preview showed content
about half an editor screen above the editor's top and stayed there. The maintainer found
it by hand while testing #180 on `large-1mb.md`. In `EditorVisibleTopTests` at an 800 pt
viewport the unfixed code reported line 2476 while line 2501 was at the top: 25 lines,
400 pt. `EditorVisibleTop` now walks layout fragments from the viewport start and returns
the first one whose frame reaches below `visibleRect.minY`. STTextView's content view keeps
the text view's vertical origin, so the two share one y axis. Only fragments inside the
laid-out viewport are visited. Highlighting and the element-cache trimmer still use the
full viewport range, because they want the prefetch band.

Alternatives: pin STTextView back to 2.3.10 (rejected: #180's A/B shows 2.4.1 is what fixes
editor scroll p95); subtract half the visible height from the viewport (rejected: depends on
STTextView's internal prefetch rule, which is clamped at the document top and may change);
`characterIndex(for:)` at the visible top (rejected: it hit-tests from the document start
and force-unwraps the window); TextKit's `textLayoutFragment(for:)` hit test (kept as the
test oracle; the walk also handles a visible top that falls between fragments).
