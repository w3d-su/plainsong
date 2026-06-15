# M4 Manual Checklist

Use this checklist before accepting M4 authoring-feature changes. Run it in a disposable Markdown
file inside a folder workspace so file switching and preview rendering are also covered.

## Setup

- [ ] Launch Plainsong from the current branch.
- [ ] Open a folder workspace that contains at least two Markdown files.
- [ ] Create or open a scratch Markdown file and make sure the preview pane is visible.

## List Continuation And Renumbering

- [ ] Type `- first`, press Enter, and confirm the next line starts with `- `.
- [ ] Press Enter again on the empty bullet and confirm the list marker is removed.
- [ ] Type `1. one`, press Enter, type `two`, and confirm the second marker is `2. `.
- [ ] In a numbered list with following items, press Enter after item 1 and confirm later items renumber.
- [ ] Select two list lines, press Tab, and confirm both lines indent together.
- [ ] Press Shift-Tab on the same selection and confirm both lines outdent together.

## Auto-Pairing And Wrap

- [ ] Type `(`, `[`, `{`, `"`, `_`, and `` ` `` at an empty caret and confirm each inserts a pair with the caret inside.
- [ ] Type the matching closing character before an existing closer and confirm the caret skips over it.
- [ ] Select text and type `*`; confirm the selection is wrapped as `*selected*`.
- [ ] Type a bare `*` at an empty caret and confirm it inserts a literal `*`.
- [ ] In an `.mdx` file, type `<` and confirm it inserts `<>` with the caret inside.
- [ ] In a `.md` file, type `<` and confirm it inserts a literal `<`.

## Code Fence Helper

- [ ] Type `` ``` `` at the start of a line and press Enter.
- [ ] Confirm Plainsong inserts a blank inner line plus a closing `` ``` `` fence and places the caret inside.
- [ ] In an existing fenced block, place the caret after the closing `` ``` `` and press Enter.
- [ ] Confirm only a normal newline is inserted; no extra closing fence appears.

## Checkbox Toggle

- [ ] Type `- [ ] task`, place the caret on the line, and press Cmd-L.
- [ ] Confirm it changes to `- [x] task`.
- [ ] Select multiple checkbox lines and press Cmd-L.
- [ ] Confirm each selected checkbox toggles without changing unselected lines.
- [ ] Place the caret on `- task` and press Cmd-L.
- [ ] Confirm it changes to `- [ ] task`.

## Table Helper

- [ ] Type a small table with a header, separator, and one body row.
- [ ] Press Tab inside a body cell and confirm the selection moves to the next editable cell.
- [ ] Press Shift-Tab and confirm the selection moves to the previous editable cell.
- [ ] Press Enter at the end of a body row and confirm a new row is inserted.
- [ ] Use Format > Format Table or Option-Cmd-F and confirm pipes are aligned.

## Format Menu And Shortcuts

- [ ] Select text and use Format > Bold; confirm it wraps with `**`.
- [ ] Repeat with Cmd-B and confirm it toggles bold off.
- [ ] Verify Italic/Cmd-I, Strikethrough/Control-Cmd-X, Inline Code/Cmd-E, and Link/Cmd-K.
- [ ] Verify Heading 1-6 with Cmd-1 through Cmd-6, then Paragraph with Cmd-0.
- [ ] Verify Quote with Shift-Cmd-Q and Code Fence with Shift-Cmd-K.
- [ ] With two workspace windows open, focus an editor and run Cmd-B.
- [ ] Confirm the command applies to the focused editor; Phase 1 windows currently share one document state.
- [ ] Move focus to the sidebar or preview and run Cmd-B.
- [ ] Confirm the command no-ops rather than applying to a background editor.

## Completion Engine

- [ ] At the start of a new empty Markdown file, type `#`.
- [ ] Confirm completion suggestions include headings, quote/list/task snippets, a table, a fenced code block, and a frontmatter block.
- [ ] Type `#` on a non-top line and confirm the frontmatter block is not suggested.
- [ ] Type `` ``` `` and confirm language suggestions include `swift`, `ts`, `python`, and `mermaid`.
- [ ] In a folder workspace, type `[post](` and confirm Markdown/MDX file paths and image paths are suggested.
- [ ] Type `[section](#` in a document with headings and confirm current-file heading anchors are suggested.
- [ ] Type `![](` and confirm only image paths are suggested.
- [ ] Type `:sm` and confirm emoji shortcode suggestions insert the Unicode emoji.
- [ ] Inside an existing YAML frontmatter block, start a new key line and confirm built-in keys plus keys from sibling files are suggested.
- [ ] In an `.mdx` file with component imports, type `<` and confirm imported component names are suggested.
- [ ] Hold normal typing in a large document and confirm typing remains responsive while completion requests appear only for trigger contexts or Control-Space.

## Preview And File-Switch Sanity

- [ ] Type a heading, list, checkbox, code fence, and table in the editor.
- [ ] Confirm the preview updates within the normal debounce interval and does not blank.
- [ ] Switch to another file in the sidebar, then switch back.
- [ ] Confirm the editor text, selection-sensitive commands, and preview still target the active file.
- [ ] Save the scratch file, close and reopen the workspace, and confirm the saved Markdown content is unchanged.
