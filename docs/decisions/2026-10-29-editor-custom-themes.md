# Editor themes are imported color palettes; user CSS stays deferred

On 2026-10-29 the owner accepted the recommendations in
`docs/custom-themes-design.md` for the first implementation slice (PR B, gates T1-T3):

- Version 1.0 ships token colors only. User CSS stays deferred behind the prerequisites
  in that design.
- Schema v1 rejects the whole file when it contains a field the decoder does not know.
  The validator walks the JSON object instead of using `JSONDecoder`, because
  `JSONDecoder` would drop unknown fields and accept a file this schema must reject.
- Themes choose colors only. They do not choose fonts.
- Mermaid keeps the built-in light and dark themes. Token-driven Mermaid colors are a
  follow-up.

This change imports those colors for the source editor. Preview tokens may be present in
the same file and are validated, but they are not sent to the preview. `setThemeTokens`
and `PROTOCOL_VERSION` 9 stay in the next slice, so this change does not touch the bridge.

Why a copy in Application Support: the sandbox can read the file once, during the open
panel, and then forget the user's URL. No bookmark is stored, and the original file is
not watched. Re-importing an id asks before overwriting that copy. Remove moves the copy
to the Trash and, when that theme was selected, selects Plainsong, because the user
deleted it. A file that is merely unreadable is different: the stored id stays, the
editor uses Plainsong for the launch, and a non-modal banner explains why, so fixing the
file and relaunching picks it up again.

A later review tightened the same rules without opening preview or bridge work.
`text`, `caret`, and `background` must be opaque, so a theme cannot hide the text,
the caret, or the background. A custom background can still inherit a built-in text
color; the 4.5:1 warning remains T7. While Increase Contrast is on, editor colors
resolve from the built-in palette.

Names are stored in NFC, trimmed, limited to 128 Unicode scalars, and rejected when
they contain control, format, line-separator, or paragraph-separator characters, or when
they start with a combining mark. Homoglyphs are not given their own denylist. Imported
themes are listed in a separate picker section, and the picker still appends `name (id)`
when a name collides with a built-in display name or another imported theme. Increase
Contrast is seeded on the main actor and updated from the workspace notification
center into a lock; theme colors do not read `NSWorkspace` while resolving. A theme file
is opened without following links and is read only after `fstat` shows a regular file.
STTextView 2.4.1 does not offer a selection-color API (`selectedLineHighlightColor` is
the current line), so a custom selection color is still painted onto
`STSelectionHighlightView`. Layout
repaints only that selection container, which lives for the life of the text view,
instead of walking every layout fragment on each keystroke.

Missing editor slots inherit the built-in `standard` colors, which are already dynamic
system colors. An omitted `dark` object inherits the built-in dark appearance for every
slot. The new `gutter` slot is the gutter track. When it is omitted, the gutter still
fills with the editor background, which is what it did before the slot existed. Line
numbers stay on the existing muted and text colors. Chrome colors are
`NSColor(name:dynamicProvider:)` values named with the theme id and hex, so an appearance
change resolves them without reloading the document, and replacing a theme does not reuse
a stale named color.

Alternatives considered are the ones in the design: shipping user CSS first, separate
editor and preview files, importing VS Code or TextMate themes, bookmarking the original
file, and allowing CSS text in the JSON. None of those is in this slice.

STTextView rebuilds selection overlays with the system selection color whenever the
viewport lays out or the appearance changes. A custom selection color is therefore
painted onto those overlay views after layout, and the layer keeps that color if
STTextView writes the system color back. The built-in selection color does not install
that paint, so ordinary typing does not walk the overlay tree.
