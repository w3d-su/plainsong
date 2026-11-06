# Render WYSIWYG tables by projecting pipes to tab stops, edit cells in place, reveal the whole table only for structure

The owner reported that Experimental WYSIWYG shows a GFM table as styled raw pipe text.
`docs/wysiwyg-release-checklist.md` §E deferred tables and requires a dedicated gate pass
before they become user-facing; `docs/table-wysiwyg-gates.md` is that gate (T0–T11). This
entry records the proposed mechanism and reveal policy. Status: **proposed, pending the T0
spike and owner approval**; nothing is wired, and tables stay raw in every mode until then.

Mechanism (candidate A, to be proven by T0): inside the existing `NSTextContentStorage`
paragraph projection (`WYSIWYGZeroWidthTextContentProjection.swift`, chosen 2026-06-26),
each row of an eligible table projects its cell-boundary pipes to `\t` and its padding,
trailing pipe and leading spaces to U+200B. Both are one UTF-16 unit, so every raw offset
survives. The projected paragraph carries `NSTextTab` stops at the table's column
positions, aligned left, center or right from the delimiter row. The delimiter row collapses
to a header rule, and a passive layer draws grid lines from laid-out fragments. The backing
string never changes, cell content stays real glyphs (IME, selection, Find and copy keep
their source-mode paths), and no attachment or U+FFFC is involved. Column widths come from
every row, so the visible-range parse expands to whole eligible tables, bounded by caps.

Reveal policy: cell content edits in place without revealing (Typora's model); a caret never
rests on hidden structure and snaps to a cell content edge (the §C.2 policy); vertical
movement skips the delimiter row; the whole table, never a single row, reveals raw when the
caret reaches the delimiter row, when Backspace/Delete would remove a hidden structural
character (first press reveals only), or when Find/Replace navigation selects a match that
crosses structure. For the §13 `wysiwygRangeNotRevealed` rule the table's owner ranges are
its structural runs, so a Replace inside cell content commits without a reveal.

Alternatives:
- Zero-width pipes with `.kern` padding for alignment: no tab characters even in
  projection, but per-glyph padding distorts caret and selection rects and sums widths by
  hand. Kept as the T0 fallback.
- Custom `NSTextLayoutFragment`: STTextView owns the layout-fragment delegate (rejected for
  the same reason on 2026-06-26), and a fragment cannot span rows.
- Embedded table view as one attachment: cell content stops being text, so editing, IME,
  Find and copy would need a second editor, and the collapsed rows stay caret-reachable.
- Overlay drawn over hidden source: no reserved geometry; hit-testing would disagree with
  the drawing.
- Reformatting the source with Format Table on open: mutates the canonical source.
- Reveal the whole table on caret entry: reflows the table on every entry and every
  arrow into it. Reveal only the caret's row: one raw row among aligned rows misreads, and
  the table reflows on leaving it.

Supersedes: none. Amends the `docs/wysiwyg-release-checklist.md` §E deferral only once
T0–T11 pass.
