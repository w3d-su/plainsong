# M5 Manual Checklist

Use this checklist before accepting M5 changes. Run the automated checks first, then perform the
manual checks in a disposable folder workspace that contains the committed fixtures and at least one
real Astro or Next.js content directory with `.mdx` posts.

Final sweep status, 2026-06-25: **not fully passed**. Automated verification passed after a minimal
editor-to-preview scroll-sync fix, and current-build UI passes covered the fixture workspace, preview
pane, MDX rendering, Markdown rendering, broken-MDX error banner display, a real Next.js content
folder sweep, and the non-placeholder Settings window. M5 remains **not accepted** until the
unchecked manual items below are completed.

Evidence from this sweep:

- Automated commands passed: `make preview-bundle`, `make build`, `make test`,
  `cd preview-src && npm run typecheck`, `cd preview-src && npm test`.
- `make test` included MarkdownCore, EditorKit, PreviewKit, WorkspaceKit, app tests,
  PerformanceTests, and preview Vitest. Current performance samples stayed under the M5 budgets.
- Current-build UI smoke used
  `/Users/davis._.su/Library/Developer/Xcode/DerivedData/Plainsong-dqqnpwbhqyqxrwbnadviosajkzol/Build/Products/Debug/Plainsong.app`
  with disposable workspace `/tmp/plainsong-m5-manual` and real Next.js project
  `/Users/davis._.su/Documents/blog`.
- UI smoke confirmed `Fixtures/kitchen-sink.mdx`, `Fixtures/kitchen-sink.md`,
  `Fixtures/product-page.mdx`, and `Fixtures/mdx-syntax-error.mdx` render/nonblank behavior where
  checked below.
- Real-content UI smoke opened all 13 `.mdx` files under `/Users/davis._.su/Documents/blog/content`;
  each rendered nonblank. That content set did not include inline body images, so real-content image
  behavior remains unchecked below.
- One checklist failure was found: editor-to-preview scroll sync did not reliably follow selection/
  visible-range movement. The current sweep fixes the bridge by emitting the selected/visible source line from
  EditorKit, adds an EditorKit regression test, and was manually rechecked on `article-template.mdx`.
- Remaining unchecked items are not assumed to pass. Settings workflow/theme toggles, the full
  broken-MDX edit/reintroduce loop, completion-popup behavior, Dock icon/light-mode polish, inline
  body-image real-content behavior, and rapid mixed-file switching still need manual validation.

## Setup

- [x] Run `make preview-bundle` after any `preview-src/` change and confirm the committed preview bundle is current. Passed in this sweep; no bundle diff.
- [x] Run `make build`. Passed in this sweep.
- [x] Run `make test`. Passed in this sweep.
- [x] Launch Plainsong from the current branch. Current DerivedData build launched and opened the disposable workspace.
- [x] Open a folder workspace containing `Fixtures/` or copies of the M5 fixtures. Opened `/tmp/plainsong-m5-manual`.
- [x] Ensure the preview pane is visible. Preview pane was toggled visible and observed.

## M4 Sequencing Gate

- [x] Confirm M4 remains accepted: completion, the Yams-backed frontmatter panel, smart paste, drag-in image handling, table helper, editing behaviors, and format commands still pass their tests/checklist. Covered by `make test` in this sweep, including MarkdownCore, EditorKit, WorkspaceKit, and app tests.
- [x] Confirm any new M5 work does not silently reopen M4 scope. This sweep adds only a minimal scroll-sync checklist fix plus docs/status updates; no new product features were added.

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
- [x] Confirm source-line anchors remain good enough for editor-to-preview scroll sync. `data-line` coverage passed in preview-src tests; a manual failure on `article-template.mdx` was fixed by emitting selected/visible source lines from EditorKit, covered by `MarkdownEditorViewTests.testEditorScrollProxyEmitsLineContainingSelectionOffset`, and manually retested with the editor around line 33 while the preview followed the same document region.

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
- [ ] Confirm the preview bridge remains live: switching from the broken fixture to another valid Markdown/MDX file renders normally. The initial broken-file banner and last-good render were observed, but this exact post-error switch was not completed manually.
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

- [x] Open Settings and confirm it is no longer a placeholder. Manually opened Settings on 2026-06-25; General, Editor, Preview, and Files panes were visible, with General controls for default folder and autosave interval.
- [ ] Change the General default folder and confirm the configured folder is used by default-folder workflows. PR #26 persists the bookmark; a macOS Documents-folder permission prompt appeared during Settings inspection, and the workflow behavior was not manually completed.
- [ ] Change the General autosave interval and confirm autosave behavior follows the configured interval. PR #26 covers preference persistence, but manual timing behavior was not completed.
- [ ] Change editor font family and confirm the active editor updates without reopening the file. PR #26 covers setting wiring; visual active-editor confirmation was not completed.
- [ ] Change editor font size and confirm the active editor updates without reopening the file. PR #26 covers setting wiring; visual active-editor confirmation was not completed.
- [ ] Toggle line numbers and confirm the active editor updates. PR #26 covers preference persistence; visual active-editor confirmation was not completed.
- [ ] Toggle typewriter sync and confirm editor/preview scroll sync behavior updates immediately. Core editor-to-preview scroll sync was fixed/rechecked in this sweep, but the Settings preference toggle behavior was not manually completed.
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
- [ ] Confirm the main window, settings window, editor, and preview remain visually coherent in light and dark appearances. Main window/editor/preview and the Settings window were observed in dark appearance; light appearance was not completed manually.

## Real Content Folder Acceptance

- [x] Open a representative Astro or Next.js content folder containing multiple `.mdx` posts. Opened `/Users/davis._.su/Documents/blog`, a Next.js project with `next.config.ts` and `content/**/*.mdx`.
- [x] Open every `.mdx` post in that folder. Opened all 13 files under `content/articles`, `content/notes`, `content/pages`, `content/photography`, `content/projects`, and `content/templates`.
- [x] Confirm each post renders non-blank preview content. All 13 real-content files rendered nonblank preview output.
- [x] Confirm imports/exports/components are represented as placeholders rather than executed. Real-content component uses rendered as non-executed placeholders/cards; import/export behavior remains covered by fixtures and preview-src tests because the representative content set did not include source-level import/export lines.
- [ ] Confirm links, images that are within the granted folder scope, headings, and code fences behave as expected. Headings, links, lists, code fences, and component placeholders were observed in the real content folder; no inline body images were present, so in-scope image behavior remains unchecked.
- [ ] Switch rapidly between `.md`, `.mdx`, and broken `.mdx` files and confirm the preview never strands on the previous document. Real-content switching across valid `.mdx` files was observed; rapid mixed `.md`/`.mdx`/broken `.mdx` switching was not completed.

## Performance Acceptance

Record results in `docs/perf-log.md` before accepting M5.

- [x] Typing latency remains below 16 ms on `Fixtures/large-1mb.md`. Current sweep max was 0.309 ms.
- [x] Highlight update for visible range remains below 50 ms with visible-range plumbing/instrumentation in place; do not count the current 250 KB inline cutoff as passing. Current sweep max was Markdown 15.876 ms, MDX 22.189 ms.
- [x] Preview render for a 100 KB document remains below 100 ms after the normal debounce. Current sweep medians were Markdown 62.257 ms, MDX 15.343 ms.
- [x] Opening a 500 KB Markdown document reaches first paint below 300 ms. PerformanceTests passed; prior recorded value remains 33.765 ms.
- [x] Host-process RSS remains below 400 MB with 8 warm sessions and 2 settled live webviews; record WebKit helper RSS as diagnostic if available, and do not count a single-webview path as passing. Current sweep reported 141.6 MB host RSS; WebKit helper aggregate 639.7 MB remained diagnostic only.
