# M5 Manual Checklist

Use this checklist before accepting M5 changes. Run the automated checks first, then perform the
manual checks in a disposable folder workspace that contains the committed fixtures and at least one
real Astro or Next.js content directory with `.mdx` posts.

Final sweep status, 2026-06-24: **not fully passed**. Automated verification passed, and a partial
current-build UI pass covered the fixture workspace, preview pane, MDX rendering, Markdown rendering,
and broken-MDX error banner behavior. M5 remains **not accepted** until the unchecked manual items
below are completed.

Evidence from this sweep:

- Automated commands passed: `make preview-bundle`, `make build`, `make test`,
  `cd preview-src && npm run typecheck`, `cd preview-src && npm test`.
- `make test` included MarkdownCore, EditorKit, PreviewKit, WorkspaceKit, app tests,
  PerformanceTests, and preview Vitest. Current performance samples stayed under the M5 budgets.
- Current-build UI smoke used
  `/Users/davis._.su/Library/Developer/Xcode/DerivedData/Plainsong-dqqnpwbhqyqxrwbnadviosajkzol/Build/Products/Debug/Plainsong.app`
  with disposable workspace `/tmp/plainsong-m5-manual`.
- UI smoke confirmed `Fixtures/kitchen-sink.mdx`, `Fixtures/kitchen-sink.md`,
  `Fixtures/product-page.mdx`, and `Fixtures/mdx-syntax-error.mdx` render/nonblank behavior where
  checked below.
- Remaining unchecked items are not assumed to pass. A later Computer Use attempt to replace the full
  STTextView content became unreliable/windowless, so settings-window and additional editor-popup
  checks were stopped instead of faked.

## Setup

- [x] Run `make preview-bundle` after any `preview-src/` change and confirm the committed preview bundle is current. Passed in this sweep; no bundle diff.
- [x] Run `make build`. Passed in this sweep.
- [x] Run `make test`. Passed in this sweep.
- [x] Launch Plainsong from the current branch. Current DerivedData build launched and opened the disposable workspace.
- [x] Open a folder workspace containing `Fixtures/` or copies of the M5 fixtures. Opened `/tmp/plainsong-m5-manual`.
- [x] Ensure the preview pane is visible. Preview pane was toggled visible and observed.

## M4 Sequencing Gate

- [x] Confirm M4 remains accepted: completion, the Yams-backed frontmatter panel, smart paste, drag-in image handling, table helper, editing behaviors, and format commands still pass their tests/checklist. Covered by `make test` in this sweep, including MarkdownCore, EditorKit, WorkspaceKit, and app tests.
- [x] Confirm any new M5 work does not silently reopen M4 scope. This docs/status sweep adds no M5 feature work.

## MDX Preview Rendering

- [x] Open `Fixtures/kitchen-sink.mdx`. Performed in the disposable workspace.
- [x] Confirm Markdown headings, paragraphs, lists, blockquotes, tables, math, Mermaid, and fenced code render normally. Observed in the preview accessibility tree and screenshot; preview-src pipeline tests also passed.
- [x] Confirm ESM `import` and `export` lines render as compact non-executed chips or equivalent placeholder UI. Observed in preview for `kitchen-sink.mdx`.
- [x] Confirm uppercase JSX flow components render as placeholder cards with component names and escaped prop summaries. Observed in preview for `Hero`, `Callout`, `Grid`, and `Charts.LineChart`.
- [x] Confirm component children containing Markdown render safely inside or near the placeholder card. Observed for `Callout`; preview-src tests also cover MDX placeholders.
- [x] Confirm inline JSX and expression nodes render as safe placeholders/code chips and do not execute JavaScript. Observed in preview and covered by preview-src tests.
- [x] Confirm lowercase HTML renders only through the approved sanitized path. Observed in preview and covered by preview-src tests.
- [x] Confirm lowercase HTML strips inline `style`, event-handler attributes, scripts, `srcdoc`, fixed-position overlays, giant dimensions, and URL-bearing background styles. Covered by PR #24 preview tests and re-run by this sweep.
- [x] Confirm inline user-authored SVG is rejected and SVG payload text/attributes do not leak into preview. Covered by PR #27 policy/test coverage and re-run by this sweep.
- [ ] Confirm source-line anchors remain good enough for editor-to-preview scroll sync. `data-line` coverage passed in preview-src tests, but manual editor-to-preview scroll sync was not rechecked in this sweep.

## Preview Asset Security

- [x] Confirm `asset://` images resolve only inside the granted file/workspace root, including symlink targets. Covered by PR #24 PreviewKit tests and re-run by this sweep.
- [x] Confirm `../` traversal and percent-encoded traversal are rejected. Covered by PR #24 PreviewKit tests and re-run by this sweep.
- [x] Confirm preview assets larger than 10 MiB are rejected before file data is read. Covered by PR #24 PreviewKit tests and re-run by this sweep.
- [x] Confirm only PNG, JPEG, GIF, and WebP assets are served through `asset://`; SVG, TIFF, BMP, text, and unknown types are rejected. Covered by PR #24 PreviewKit tests and re-run by this sweep.
- [x] Confirm pasted/dragged external image files use file copy after metadata validation instead of whole-file `Data(contentsOf:)` reads. Covered by PR #24 WorkspaceKit tests and re-run by this sweep.

## MDX Error Liveness

- [x] Open `Fixtures/mdx-syntax-error.mdx`. Performed in the disposable workspace.
- [x] Confirm the preview shows an inline parse/render error banner with a useful line reference when available. Observed `MDX syntax error on line 14`.
- [x] Confirm the preview pane does not blank. Observed last valid render under the error banner.
- [ ] Confirm the preview bridge remains live: switching to another valid Markdown/MDX file renders normally. Not completed after the UI automation session became unreliable; manual recheck required.
- [ ] Edit the broken fixture into valid MDX and confirm the preview recovers without relaunching. Covered by preview-src test `surfaces syntax errors without blanking and recovers after a fix`, but not completed manually in the app.
- [ ] Reintroduce a syntax error and confirm the last good render remains visible where possible. Initial broken-file path showed last good render, but this specific edit/reintroduce loop was not completed manually.

## MDX Editor Source Experience

- [x] Open `Fixtures/product-page.mdx`. Opened as `content/posts/astro-post.mdx` in the disposable workspace.
- [x] Confirm top-level `import` lines are visually distinct from prose. Observed in the current-build editor.
- [x] Confirm multiline JSX blocks are visually distinct from Markdown body text. Observed in `product-page.mdx`.
- [x] Confirm self-closing JSX components and closing tag lines are styled consistently. Observed in `product-page.mdx` / `kitchen-sink.mdx`; EditorKit highlighting tests also passed.
- [x] Confirm fenced `tsx` code retains code-fence highlighting behavior. Observed and covered by EditorKit tests.
- [x] Confirm ordinary `.md` files still use Markdown highlighting and are not treated as MDX. Observed `Fixtures/kitchen-sink.md` with Markdown badge; EditorKit tests also passed.
- [ ] M4 completion re-verification: Type `<` in an `.mdx` file with imports and confirm imported component completions appear. Completion engine/workspace tests passed, but the UI completion popup was not manually rechecked.
- [ ] M4 completion re-verification: Confirm MDX component completion does not appear inside obvious non-tag contexts such as fenced code blocks. Engine tests passed, but the UI completion popup was not manually rechecked.

## Settings And Themes

M5 #16 scope covers built-in editor/preview themes and preference wiring. Custom editor-theme JSON
files and user CSS overrides are deferred by Decision Log until separate import/sanitizer designs
exist.

- [ ] Open Settings and confirm it is no longer a placeholder. Not manually completed in this sweep.
- [ ] Change the General default folder and confirm the configured folder is used by default-folder workflows. PR #26 persists the bookmark, but workflow behavior was not manually completed.
- [ ] Change the General autosave interval and confirm autosave behavior follows the configured interval. PR #26 covers preference persistence, but manual timing behavior was not completed.
- [ ] Change editor font family and confirm the active editor updates without reopening the file. PR #26 covers setting wiring; visual active-editor confirmation was not completed.
- [ ] Change editor font size and confirm the active editor updates without reopening the file. PR #26 covers setting wiring; visual active-editor confirmation was not completed.
- [ ] Toggle line numbers and confirm the active editor updates. PR #26 covers preference persistence; visual active-editor confirmation was not completed.
- [ ] Toggle typewriter sync and confirm editor/preview scroll sync behavior updates immediately. PR #26 covers preference persistence; manual scroll behavior was not completed.
- [x] Confirm the two built-in editor themes are available. Covered by PR #26 EditorKit tests.
- [x] Confirm custom editor-theme JSON files remain deferred by Decision Log and are not exposed as incomplete UI. Deferred in `agent.md` Decision Log and §11.
- [ ] Change editor theme or appearance and confirm syntax colors update without affecting typing responsiveness. Built-in theme tests passed, but visual color update plus typing-responsiveness check was not completed manually.
- [ ] Change preview theme to light and dark and confirm preview colors update independent of the OS appearance. Bridge/persistence tests passed, but visual theme check was not completed manually.
- [x] Confirm user CSS overrides remain deferred by Decision Log and are not exposed as incomplete UI. Deferred in `agent.md` Decision Log and §11.
- [ ] Confirm Mermaid output follows the selected preview theme. Not manually completed in this sweep.
- [x] With remote images disabled, confirm `https:` preview images are blocked by the default image policy. Covered by PR #26 preview-src tests and re-run by this sweep.
- [x] Enable Allow Remote Images and confirm `https:` preview images load without allowing other remote script/style loads. Covered by PR #26 preview-src tests and CSP policy; not visually rechecked.
- [x] Change the image-paste asset-folder pattern and confirm pasted images are stored under the configured folder. Covered by PR #26 app tests.
- [x] Change the default file extension between `.md` and `.mdx` and confirm new files use the selected extension. Covered by PR #26 app tests.
- [ ] Quit and relaunch, then confirm settings persist. UserDefaults persistence is covered by PR #26 app tests, but the manual relaunch check was not completed.

## App Icon And Polish

- [x] Build and launch the app from Finder or Xcode. Built and launched current DerivedData app.
- [ ] Confirm the Dock/app switcher icon is the Plainsong icon, not the generic placeholder. Not manually completed in this sweep.
- [x] Confirm the app accent color appears in standard controls where applicable. Observed in the current-build main window and backed by `NSAccentColorName`.
- [ ] Confirm the main window, settings window, editor, and preview remain visually coherent in light and dark appearances. Main window/editor/preview were observed in dark appearance; Settings and light appearance were not completed manually.

## Real Content Folder Acceptance

- [ ] Open a representative Astro or Next.js content folder containing multiple `.mdx` posts. A disposable representative folder with copied MDX posts was used for smoke, but a real project content folder was not supplied/verified.
- [ ] Open every `.mdx` post in that folder. Not completed.
- [ ] Confirm each post renders non-blank preview content. Partially observed for copied fixtures only; not completed for a real content folder.
- [ ] Confirm imports/exports/components are represented as placeholders rather than executed. Observed for copied fixtures only; not completed for a real content folder.
- [ ] Confirm links, images that are within the granted folder scope, headings, and code fences behave as expected. Partially observed for copied fixtures only; not completed for a real content folder.
- [ ] Switch rapidly between `.md`, `.mdx`, and broken `.mdx` files and confirm the preview never strands on the previous document. Partial switching was observed; rapid switching after the broken file was not completed.

## Performance Acceptance

Record results in `docs/perf-log.md` before accepting M5.

- [x] Typing latency remains below 16 ms on `Fixtures/large-1mb.md`. Current sweep max was 0.373 ms.
- [x] Highlight update for visible range remains below 50 ms with visible-range plumbing/instrumentation in place; do not count the current 250 KB inline cutoff as passing. Current sweep max was Markdown 17.244 ms, MDX 22.280 ms.
- [x] Preview render for a 100 KB document remains below 100 ms after the normal debounce. Current sweep medians were Markdown 49.663 ms, MDX 15.661 ms.
- [x] Opening a 500 KB Markdown document reaches first paint below 300 ms. PerformanceTests passed; prior recorded value remains 33.765 ms.
- [x] Host-process RSS remains below 400 MB with 8 warm sessions and 2 settled live webviews; record WebKit helper RSS as diagnostic if available, and do not count a single-webview path as passing. Current sweep reported 136.1 MB host RSS; WebKit helper aggregate remained diagnostic only.
