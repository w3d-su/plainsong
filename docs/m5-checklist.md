# M5 Manual Checklist

Use this checklist before accepting M5 changes. Run the automated checks first, then perform the
manual checks in a disposable folder workspace that contains the committed fixtures and at least one
real Astro or Next.js content directory with `.mdx` posts.

## Setup

- [ ] Run `make preview-bundle` after any `preview-src/` change and confirm the committed preview bundle is current.
- [ ] Run `make build`.
- [ ] Run `make test`.
- [ ] Launch Plainsong from the current branch.
- [ ] Open a folder workspace containing `Fixtures/` or copies of the M5 fixtures.
- [ ] Ensure the preview pane is visible.

## M4 Sequencing Gate

- [ ] Confirm M4 remains accepted: completion, the Yams-backed frontmatter panel, smart paste, drag-in image handling, table helper, editing behaviors, and format commands still pass their tests/checklist.
- [ ] Confirm any new M5 work does not silently reopen M4 scope.

## MDX Preview Rendering

- [ ] Open `Fixtures/kitchen-sink.mdx`.
- [ ] Confirm Markdown headings, paragraphs, lists, blockquotes, tables, math, Mermaid, and fenced code render normally.
- [ ] Confirm ESM `import` and `export` lines render as compact non-executed chips or equivalent placeholder UI.
- [ ] Confirm uppercase JSX flow components render as placeholder cards with component names and escaped prop summaries.
- [ ] Confirm component children containing Markdown render safely inside or near the placeholder card.
- [ ] Confirm inline JSX and expression nodes render as safe placeholders/code chips and do not execute JavaScript.
- [ ] Confirm lowercase HTML renders only through the approved sanitized path.
- [ ] Confirm source-line anchors remain good enough for editor-to-preview scroll sync.

## MDX Error Liveness

- [ ] Open `Fixtures/mdx-syntax-error.mdx`.
- [ ] Confirm the preview shows an inline parse/render error banner with a useful line reference when available.
- [ ] Confirm the preview pane does not blank.
- [ ] Confirm the preview bridge remains live: switching to another valid Markdown/MDX file renders normally.
- [ ] Edit the broken fixture into valid MDX and confirm the preview recovers without relaunching.
- [ ] Reintroduce a syntax error and confirm the last good render remains visible where possible.

## MDX Editor Source Experience

- [ ] Open `Fixtures/product-page.mdx`.
- [ ] Confirm top-level `import` lines are visually distinct from prose.
- [ ] Confirm multiline JSX blocks are visually distinct from Markdown body text.
- [ ] Confirm self-closing JSX components and closing tag lines are styled consistently.
- [ ] Confirm fenced `tsx` code retains code-fence highlighting behavior.
- [ ] Confirm ordinary `.md` files still use Markdown highlighting and are not treated as MDX.
- [ ] M4 completion re-verification: Type `<` in an `.mdx` file with imports and confirm imported component completions appear.
- [ ] M4 completion re-verification: Confirm MDX component completion does not appear inside obvious non-tag contexts such as fenced code blocks.

## Settings And Themes

- [ ] Open Settings and confirm it is no longer a placeholder.
- [ ] Change the General default folder and confirm the configured folder is used by default-folder workflows.
- [ ] Change the General autosave interval and confirm autosave behavior follows the configured interval.
- [ ] Change editor font family and confirm the active editor updates without reopening the file.
- [ ] Change editor font size and confirm the active editor updates without reopening the file.
- [ ] Toggle line numbers and confirm the active editor updates.
- [ ] Toggle typewriter sync and confirm editor/preview scroll sync behavior updates immediately.
- [ ] Confirm the two built-in editor themes are available.
- [ ] Add or select an editor-theme JSON file from Application Support and confirm its name, colors, and traits load correctly.
- [ ] Change editor theme or appearance and confirm syntax colors update without affecting typing responsiveness.
- [ ] Change preview theme to light and dark and confirm preview colors update independent of the OS appearance.
- [ ] Add a user CSS override and confirm it loads after the selected preview theme.
- [ ] Confirm Mermaid output follows the selected preview theme.
- [ ] With remote images disabled, confirm `https:` preview images are blocked by the strict CSP/default image policy.
- [ ] Enable Allow Remote Images and confirm `https:` preview images load without allowing other remote script/style loads.
- [ ] Change the image-paste asset-folder pattern and confirm pasted images are stored under the configured folder.
- [ ] Change the default file extension between `.md` and `.mdx` and confirm new files use the selected extension.
- [ ] Quit and relaunch, then confirm settings persist.

## App Icon And Polish

- [ ] Build and launch the app from Finder or Xcode.
- [ ] Confirm the Dock/app switcher icon is the Plainsong icon, not the generic placeholder.
- [ ] Confirm the app accent color appears in standard controls where applicable.
- [ ] Confirm the main window, settings window, editor, and preview remain visually coherent in light and dark appearances.

## Real Content Folder Acceptance

- [ ] Open a representative Astro or Next.js content folder containing multiple `.mdx` posts.
- [ ] Open every `.mdx` post in that folder.
- [ ] Confirm each post renders non-blank preview content.
- [ ] Confirm imports/exports/components are represented as placeholders rather than executed.
- [ ] Confirm links, images that are within the granted folder scope, headings, and code fences behave as expected.
- [ ] Switch rapidly between `.md`, `.mdx`, and broken `.mdx` files and confirm the preview never strands on the previous document.

## Performance Acceptance

Record results in `docs/perf-log.md` before accepting M5.

- [ ] Typing latency remains below 16 ms on `Fixtures/large-1mb.md`.
- [ ] Highlight update for visible range remains below 50 ms with visible-range plumbing/instrumentation in place; do not count the current 250 KB inline cutoff as passing.
- [ ] Preview render for a 100 KB document remains below 100 ms after the normal debounce.
- [ ] Opening a 500 KB Markdown document reaches first paint below 300 ms.
- [ ] Host-process RSS remains below 400 MB with 8 warm sessions and 2 settled live webviews; record WebKit helper RSS as diagnostic if available, and do not count a single-webview path as passing.
