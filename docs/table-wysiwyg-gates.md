# Tables in WYSIWYG — Sub-Gate Specification

> **Status: T0 checked (mechanism A GO, 2026-11-06). T1–T11 unchecked.**
> The owner approved the mechanism and reveal policy on 2026-11-06. The T0 spike is reachable
> only through an internal test hook; tables stay raw in every mode until T1–T11 pass. This document is the dedicated sub-gate that
> `docs/wysiwyg-release-checklist.md` §E requires before a deferred construct becomes
> user-facing, following the link-folding (`docs/link-folding-gates.md`) and image-thumbnail
> (`docs/image-thumbnail-gates.md`) pattern. When every gate is checked, tables render only in
> the off-by-default Experimental WYSIWYG mode (`.inlineFoldRevealWithLinkFolding`); source
> modes, kill-switch fallback, and stable/default promotion stay unchanged.

Created 2026-11-06 after an owner report: in Experimental WYSIWYG a table such as
`| 123|234|345|` / `| ----- | ----- | ---- |` shows as styled raw pipe text. See `agent.md`
§13, `docs/wysiwyg-release-checklist.md` §A/§C/§E, and
`docs/decisions/2026-11-06-wysiwyg-table-rendering.md`.

## 1. Scope

- **In scope:** GFM pipe tables that tree-sitter parses as `pipe_table` (header row,
  delimiter row, zero or more body rows) at top level of the document, in `.md` and `.mdx`.
  While the table is not revealed, each row lays out as aligned columns: pipes and cell
  padding are hidden, header cells are bold, column alignment follows the delimiter row
  (`---`, `:---`, `:---:`, `---:`), the delimiter row collapses to a header rule, and thin
  grid lines separate rows and columns. Cell content stays real text: it is typed, selected,
  composed (IME), copied and found exactly as in source mode.
- **Stays raw text (v1), deterministically:** tables nested in a block quote or list item;
  tables whose source contains U+0009 (a literal tab would jump a tab stop); tables whose
rows disagree on having a leading pipe; tables in which
  any row has more cells than the header (GFM drops the extra cells, and hiding them would
  hide source text); tables without a leading pipe whose first column is center- or
  right-aligned (there is no character to carry the first tab, §3); tables whose natural
  width exceeds the text container (no horizontal scroll, no cell wrapping in v1); tables over
  the T10 caps (500 rows, 32 columns, 32 KiB of source). Rows with fewer cells than the header
  render with empty trailing cells, as GFM does.
- **Out of scope (v1):** cell wrapping, column resizing, row/column insert/delete UI
  (the existing table helper and Format Table ⌥⌘F remain the editing tools), sorting,
  rendered or TSV copy, an AX table/row/cell hierarchy, horizontally scrolling wide tables.
  Each needs its own future gate.

## 2. Why tables are harder than links and images

Every shipped fold is inline and lives inside one paragraph. Tables break three assumptions:

1. **A multi-paragraph construct.** The §A mechanism
   (`WYSIWYGZeroWidthTextContentProjection.swift`) projects one `NSTextParagraph` at a time,
   and each table row is its own paragraph. Column widths depend on every row, so the
   presentation of one row depends on text in other paragraphs, including rows outside the
   visible range.
2. **Horizontal geometry that is not the source's.** Links fold to zero width and images
   reserve one canvas; a table moves cell content to x positions that no character's own
   advance produces. Caret, hit-testing and selection rects must stay correct over that
   geometry.
3. **Structure that is editable text.** Pipes and the delimiter row are syntax the user may
   need to edit (merge cells, change alignment), but most edits happen inside cells. A
   reveal policy borrowed from links (reveal on touch) would reflow the whole table every time
   the caret enters it.

## 3. Mechanism options (T0 spike decides; record in the Decision Log)

| Option | Sketch | Pros | Risks | Stance |
|---|---|---|---|---|
| **A. Tab-stop row projection** | Inside the existing paragraph projection, for each row of an eligible table: every cell-boundary pipe becomes `\t` (U+0009, one UTF-16 unit, so the projected paragraph keeps every offset); cell padding, a trailing pipe and line-leading spaces become U+200B, like folded delimiters. The projected paragraph gets an `NSParagraphStyle` with one left-aligned `NSTextTab` per cell, computed per row and offset inside the column for center and right alignment (per the delimiter row). The row's last structural character projects to a hanging space instead (T0). The delimiter row projects to U+200B with a collapsed line height and is drawn as the header rule. A passive grid layer draws rules from laid-out fragment frames and the stop positions. | One mechanism family with the shipped §A projection; backing string untouched; cell glyphs are the real characters, so IME, selection, Find highlight and copy need no new text path; native TextKit line layout, caret rects and hit-testing; no attachment, no U+FFFC. | Column widths must be measured across all rows (§2.1); a projected `\t` must never leak into copy, AX or undo; hit-testing in a tab gap returns a structural offset (snap, §T3); collapsed delimiter-row geometry and the line-number gutter; cell content wider than its column jumps to the next stop during IME composition before re-measure. | **Primary candidate — spike first** |
| **B. Zero-width pipes + kern padding** | Same projection, but every structural character becomes U+200B, and alignment comes from `.kern` on the last content glyph (left), or on the U+200B before the content (right/center), sized to the column. | No tab characters anywhere, even in projection. | Kern is per-glyph advance padding: caret and selection rects inside the padded glyph look wrong; widths are summed by hand per row instead of laid out by TextKit; rounding drift across rows. | Fallback if A fails T0 hit-testing or tab-leak proofs |
| **C. Custom `NSTextLayoutFragment`** | Owner-drawn table fragment. | "Correct" TextKit 2 answer on paper; could draw a real grid. | STTextView owns `textLayoutManager.delegate` and returns `STTextLayoutFragment` (rejected for the same reason on 2026-06-26, §A.2); one fragment per paragraph still cannot span rows. | Rejected unless STTextView grows an API |
| **D. Embedded table view (attachment)** | Project the first row to one attachment that hosts a rendered table view; collapse the other rows. | Full visual control (borders, padding, wrapping). | Cell content stops being text: in-place editing, IME, Find highlight, selection and copy would need a second editor inside the view; N hidden paragraphs stay caret-reachable; U+FFFC risk returns at block scale. | Rejected |
| **E. Overlay view over hidden source** | Fold all rows to zero width and draw a table over them. | No layout changes. | Text layout reserves no geometry for the overlay; hit-testing and selection would disagree with what is drawn. | Rejected |
| **F. Reformat source (Format Table on open)** | Pad cells in the backing string so pipes align. | Trivial. | Mutates the canonical source for presentation; dirty documents on open. | Rejected |

## 4. Reveal and editing policy (decided here, proven in T3/T4/T7)

Typora edits a rendered table cell by cell and never shows the pipes; Plainsong's §C policy
reveals a construct's raw syntax when the caret touches it. For tables v1 combines them:

- **Cell content edits in place.** A caret or selection inside cell content does not reveal
  the table. Inline constructs inside a cell (bold, code, links, images) keep their own
  reveal-on-touch rules. Typing re-measures the table on the next presentation pass.
- **The caret never rests on hidden structure.** A collapsed caret that would land on a
  pipe, cell padding, a trailing pipe or leading spaces snaps to the nearest cell content
  edge, by direction for arrows and nearest for clicks (the §C.2 policy). In an empty cell
  the caret rests at the content location `TableEditing` uses for that cell. Left/Right at a
  content edge moves to the adjacent cell's content edge, then off the table at the row ends.
- **Vertical movement skips the delimiter row** while the table is rendered; Up from the
  first body row lands in the header and Down from the header lands in the first body row,
  at the same x where possible.
- **The whole table reveals raw** (never a single row: a raw row among aligned rows
  misreads and reflows the table twice) when:
  1. a caret or selection endpoint lands on the delimiter row (pointer click on the header
     rule; Shift-extension onto it);
  2. Backspace at a cell's content start or Delete at its content end would remove a hidden
     structural character: the first press reveals and deletes nothing, the next press
     edits the raw text;
  3. Find/Replace navigation selects a match that intersects hidden structure (T7).
  The table folds again once the caret and selection leave its source range.
- **Selections keep raw offsets.** A selection across cells or rows keeps the table rendered
  and covers exact raw UTF-16 offsets, pipes included; it is never clamped (§C.3). Copy is
  exact raw Markdown (§C.4); there is no rendered or TSV copy.
- **Existing helpers stay authoritative.** Tab/Shift-Tab cell navigation, Enter row insertion
  and Format Table (⌥⌘F) keep running on raw source through `TableEditing`; the presentation
  uses the same cell boundaries, so a Tab-selected cell is always cell content.

## 5. Gates

### T0 — Mechanism spike (blocks everything, mirrors checklist §A)
- [x] A spike PR proves option A on one hardcoded 3×3 table behind the development hook:
  backing string byte-identical; projected paragraph length equals the raw length on every
  row (the existing precondition); cell content starts align across rows within 0.5 pt for
  left, center and right columns; the collapsed delimiter row adds no line inflation and does
  not displace sibling lines (the B13 assertion extended); the line-number gutter draws one
  sane number per source row with no overlap; a real-`NSEvent` click in a tab gap resolves
  to a structural offset that snaps per §4; and **no U+0009, U+200B or U+FFFC** appears in
  pasteboard (plain and RTF), `AXValue`, `AXSelectedText` or the undo stack. If A fails any
  of these, B is spiked against the same list. The Decision Log entry records the result
  before any production PR.
  **Evidence (2026-11-06):** `setWYSIWYGTableT0SpikeEnabled(_:)` (internal; a line scan
  stands in for T1's tree-sitter model) on a 3×3 table with left, center and right columns.
  - `WYSIWYGTableMechanismSpikeTests`
    (`testT0ProjectionKeepsBackingStringAndEveryRawOffset`,
    `testT0HeaderCellsAreBoldOnlyInProjection`,
    `testT0CellContentAlignsAcrossRowsForLeftCenterAndRightColumns`,
    `testT0CollapsedDelimiterRowDoesNotInflateOrDisplaceSiblingLines`,
    `testT0GutterNumbersEveryRowButTheCollapsedDelimiterWithoutOverlap`,
    `testT0RealPointerClicksInTabGapsSnapToTheNearestCellContentEdge`,
    `testT0ArrowsSkipHiddenStructureBetweenCells`,
    `testT0CopyAccessibilityAndUndoCarryNoProjectionCharacters`,
    `testT0DisablingTheSpikeRestoresRawLayout`) and `WYSIWYGTableRowCaretSnapTests`.
  - MarkdownCore `MarkdownTableRowStructure` (`MarkdownTableRowStructureTests`) is now the one
    cell-boundary definition; `TableEditing` reads cells through it and its tests are unchanged.
  - Findings that amend option A: (1) U+200B at the end of a line reports x = 0 in TextKit's
    layout, so the last cell's segment frame (selection, caret and IME rects) collapsed; the
    row's last structural character now projects to one hanging space. (2) TextKit's
    `characterIndex(for:)` returns a tab's own index for any click inside it, so
    `WYSIWYGPointerHitTest` resolves a click past a tab's middle to the offset after it.
    (3) Alignment uses per-row left tab stops only, so one TextKit tab path covers every
    column. (4) The collapsed delimiter row draws no line number; every other row keeps its
    number and none overlap. Option B was not needed.
  - Outside this gate: the same line-end U+200B behavior already empties the segment frame
    of shipped folds whose closing delimiter ends a line (`A **bold**`); tracked separately.

### T1 — Model correctness
- [ ] A pure table region model (SyntaxKit, from tree-sitter `pipe_table`,
  `pipe_table_header`, `pipe_table_delimiter_row`, `pipe_table_row` and `|` nodes) produces
  exact UTF-16 ranges for the table, each row, each cell's content, and each structural run
  (leading spaces, pipes, padding, trailing pipe), plus per-column alignment. Cell
  boundaries and trimmed content ranges come from one definition shared with MarkdownCore
  `TableEditing` (made public as a pure structure, not duplicated), so caret snapping and the
  Tab helper agree. Escaped pipes `\|` and pipes inside code spans follow GFM. Every §1
  ineligibility rule is decided per table and provably leaves it raw. The visible-range parse
  expands to whole eligible tables (bounded by the T10 caps), so scrolling never changes
  column widths. Table regions do not alter existing inline fold regions inside cells.

### T2 — Render policy
- [ ] Column widths are the maximum measured width of each column's *presented* cell
  content (inline folds applied, header in bold), plus fixed cell padding; CJK, emoji and
  combining sequences measure correctly. Alignment left/center/right matches the delimiter
  row. The grid layer draws the header rule, row rules and column rules from laid-out
  fragments only (viewport-bounded, no hit-testing, no first-responder), and is removed when
  the table reveals or WYSIWYG turns off. A table wider than the text container stays raw and
  is re-evaluated on resize. Theme, appearance and Increase Contrast changes recolor the
  grid without reloading. Empty cells, a header-only table, rows with fewer cells, and a
  table at document start/end render without shifting unrelated lines.

### T3 — Caret, movement and reveal
- [ ] Every §4 movement rule holds for arrows, Option-arrows, Home/End and ⌘←/⌘→, with
  composed-character endpoints (emoji, CJK) valid at cell edges. Vertical movement skips the
  delimiter row. Each reveal trigger reveals the whole table in one presentation pass and no
  other trigger does; leaving the table folds it again. Backspace/Delete at a structural
  boundary reveals without mutating source. Tab/Shift-Tab and Enter (`TableEditing`) produce
  the same source as in source mode and leave the table rendered with the caret in cell
  content.

### T4 — Selection, copy and paste
- [ ] Selections within a cell, across cells, across rows, including the delimiter row,
  and Select All keep exact raw UTF-16 offsets and never clamp. Plain and RTF copy are the
  exact raw bytes: no projected U+0009, U+200B or U+FFFC reaches them. Pasting
  single- and multi-line text into a rendered cell mutates the backing source exactly as in
  source mode; pasting a pipe adds a cell on the next pass.

### T5 — IME (owner-run)
- [ ] `PLAINSONG_RUN_ACTUAL_IME=1` Zhuyin (`com.apple.inputmethod.TCIM.Zhuyin`) and
  Pinyin – Traditional (`com.apple.inputmethod.TCIM.Pinyin`) composition in a header cell, a
  body cell's first, middle and last column, an empty cell, and a cell adjacent to a folded
  inline construct: no source corruption, no caret escape, no premature commit, table
  presentation skipped while marked text exists (the existing rule), the candidate window
  anchored at the caret, and the table re-measured after commit. Composition that overruns
  its column during marking is accepted visually; after commit the row realigns.

### T6 — Pointer
- [ ] Real-`NSEvent` clicks in cell content place the caret at the hit glyph; clicks in a
  tab gap, on a column rule or past a row's last cell snap per §4; a click on the header rule
  reveals the table. Drag selection across cells and rows keeps raw offsets and copies raw
  Markdown without revealing; Shift-click extension keeps raw offsets; double-click selects a
  word without crossing a pipe; triple-click selects the raw row paragraph.

### T7 — Find and Replace
- [ ] Find highlights matches in cell content in place; a match spanning hidden structure
  highlights its visible parts. The table's *owner ranges* for the §13
  `wysiwygRangeNotRevealed` rule are its structural runs, not its whole source range: a
  single Replace whose match lies inside cell content commits without revealing the table
  (no folded attribute over the match, so the existing rule already admits it). A match
  intersecting structure is first selected, which reveals the table (§4 trigger 3); Replace
  commits only once the last applied presentation at the current revision shows the table
  revealed, and otherwise refuses with zero effect. Replace All suspends table presentation
  in the same single suspension as folds and images, commits one undo step, and re-derives
  presentation afterwards; a failed batch resets table caches with the others.

### T8 — Undo/redo
- [ ] Presentation (projection, paragraph style, grid layer, reveal state) never registers
  undo. Undo/redo of cell edits, Tab/Enter helper edits, Format Table and pasted pipes
  restores exact source and re-measures the table with no stale tab stops or grid rules.

### T9 — Accessibility
- [ ] `AXValue` and `AXSelectedText` stay exact raw source; `AXBoundsForRange` for a range in
  cell content returns the rendered rects. VoiceOver reads raw Markdown as in source mode;
  an AX table hierarchy is deferred (§1) and recorded as a known limitation in the
  checklist.

### T10 — Performance
- [ ] On `Fixtures/large-1mb.md` (1,274 pipe tables, so it is the many-tables document; no new
  fixture needed): visible-range recompute with table presentation stays ≤ 50 ms
  (CI-informational per R15, hard locally); typing in a cell of a visible table stays
  < 16 ms per keystroke, including scheduling the re-measure, with no O(document) main-thread
  work (`docs/perf-log.md` main-thread rules); column measurement covers only tables
  intersecting the visible range and is cached by table source and font/theme; tables past
  the caps (500 rows, 32 columns, 32 KiB) stay raw. Results are recorded in
  `docs/perf/YYYY-MM-DD-wysiwyg-tables.md` with machine load, as interleaved A/B against
  WYSIWYG without tables.

### T11 — Mode integration and regression
- [ ] Table presentation runs only under `.inlineFoldRevealWithLinkFolding` behind the
  existing Experimental flag, WYSIWYG layout and mechanism-health gates; the kill switch and
  disable-from-WYSIWYG fallback drop it with the rest of the presentation. Source-only and
  source+preview are byte-for-byte unchanged (the §A.3 invariants), the preview pipeline is
  untouched, App and MarkdownCore import no STTextView, and full `make test` passes.

## 6. Exit criteria

T0–T11 checked with named automated and owner-run evidence. Then the
`docs/wysiwyg-release-checklist.md` §E "Tables — stay raw" line becomes "included only in
Experimental WYSIWYG after T0–T11", `agent.md` §13 replaces "tables may initially stay raw"
with the shipped policy, and a Decision Log entry records the inclusion. Stable/default
promotion stays governed by checklist §F/D.4 and is not claimed.
