# A projected U+200B that ends a line becomes a near-zero-width hanging space in WYSIWYG

The WYSIWYG paragraph projection (`WYSIWYGZeroWidthTextContentProjection.swift`) turns
folded delimiters into equal-length U+200B runs, and an image span into U+FFFC plus U+200B
padding. TextKit 2 places a U+200B at x = 0 when it ends a line. In `A **bold**\n` with
both `**` folded, `NSTextLineFragment.locationForCharacter` returns 0 for offsets 8 and 9,
the segment frame of `bold` (`enumerateTextSegments`) has zero width, and the caret at 8 or 9
is drawn at the line start. An image on its own line had a zero-width attachment frame, and
the caret after it was drawn before it. So the selection highlight, caret rect, Find
highlight and IME candidate rect were wrong for any bold, italic, strike, code or link span,
or image, that ends a line (LF, CRLF or end of document). The table T0 spike
(w3d-su/plainsong#249) found the same behavior for a row's trailing pipe.

`WYSIWYGLineEndHangingSpace` runs after the fold and image projection steps. A projected
run (folded delimiter or image padding) can end at a line terminator (LF, CR, NEL, U+2028,
U+2029) or at the end of the paragraph. For each such run it replaces the run's last
U+200B with U+0020. That space gets the same font face at 0.01 pt, and a `.kern` equal to
minus that font's space advance. Trailing whitespace hangs past the line end, so the U+200B
units before it keep their real positions. Both the font and the kern are needed. TextKit
measures a range that ends in trailing whitespace from the unkerned advance, so with a kern
alone, a selection over the closing delimiter was one space advance (8 pt) too wide. The
small font alone left the caret at the line end, and the line's typographic width, 0.006 pt
too wide.

Measured on SF Mono 13 for `A **bold**`: the content frame is 16.1 → 48.2 pt instead of
empty, and the caret at offsets 8, 9 and 10 is at 48.2 pt. The line's typographic width stays
48.2 pt, and a segment over the hidden `**` or the whole line ends within 0.01 pt of the
content end. The invariants in `docs/wysiwyg-release-checklist.md` §A.3 hold. One UTF-16 unit
replaces one, and the backing string is untouched. Copy and the accessibility value stay raw
Markdown, and no width is added before the line end. Text the user typed, including a raw
U+200B at the line end, is never rewritten. Line height is unchanged, because a smaller run
cannot raise a line. Evidence: `WYSIWYGLineEndFoldGeometryTests` (bold, code and link with
LF, CRLF and end of document, and an image line), and the full EditorKit suite.

The checklist's §A.4 rejected a negative kern or tiny font as the way to hide delimiters.
That approach shrinks visible glyphs, so it leaves measurable, selectable advance and is
fragile across fonts and zoom. This decision keeps U+200B as the hiding mechanism. Only one
unit per line end changes, and it is a space, which has no ink. Its kern is computed from
that run's own font, so the test also passes for proportional faces and for sizes up to
31 pt. The space keeps an offset that U+200B already had, so it adds no selectable position.

Not covered: a soft wrap. U+200B is a line-break opportunity, so a wrapped visual line could
end inside a folded run, for example `**a**~~b~~` with no space at the wrap point. Line
breaks are chosen at layout time, after projection, and this change does not touch them.
The table projection in #249 can use this pass instead of its own hanging space once both
land.

Alternatives:
- Other zero-width characters at the line end (U+2060, U+200C, U+FEFF): each measured at
  x = 0, like U+200B. U+200D joins the previous glyph's cluster and drops that character
  from the content frame.
- A full-size hanging space, as in the table T0 spike: fixes the content frame. But the
  caret at the line end, the line's typographic width and any selection over the delimiter
  move one space advance to the right.
- A hanging space with only a negative kern: exact caret and line width, but a selection
  over the delimiter still paints the unkerned 8 pt.
- Project every unit of the closing run to spaces: each space would add its own caret stop
  past the content end.
