# M5 Manual Checklist

Use this checklist before accepting M5 changes. Run the automated checks first, then perform the
manual checks in a disposable folder workspace that contains the committed fixtures and at least one
real Astro or Next.js content directory with `.mdx` posts.

Final sweep status, 2026-06-25 on `m5-checklist-blockers`: **not fully passed**. Automated
verification passed, and current-build UI passes covered the fixture workspace, preview pane, MDX
rendering, Markdown rendering, broken-MDX error banner display, post-error file switching, a
representative Next.js content folder with an in-scope body image, rapid mixed-file switching,
Settings/theme workflows, preview theme/Mermaid behavior, app icon wiring, and light/dark visual
polish. M5 remains **not accepted** until the unchecked manual editor-input items below are
completed.

Evidence from this sweep:

- Automated commands passed on this branch: `make preview-bundle`, `make build`, `make test`,
  `cd preview-src && npm run typecheck`, `cd preview-src && npm test`, and `git diff --check`.
- `make test` included MarkdownCore, EditorKit, PreviewKit, WorkspaceKit, app tests,
  PerformanceTests, and preview Vitest. Current performance samples stayed under the M5 budgets.
- Current-build UI smoke used
  `/Users/davis._.su/Library/Developer/Xcode/DerivedData/Plainsong-dkqntqzpeifzzagftlsxiaticdze/Build/Products/Debug/Plainsong.app`
  with disposable fixture workspace `/tmp/plainsong-m5-checklist/Fixtures` and representative
  Next.js content folder `/tmp/plainsong-m5-real-next`.
- UI smoke confirmed `Fixtures/kitchen-sink.mdx`, `Fixtures/kitchen-sink.md`,
  `Fixtures/product-page.mdx`, and `Fixtures/mdx-syntax-error.mdx` render/nonblank behavior where
  checked below.
- Real-content UI smoke opened `/tmp/plainsong-m5-real-next/content/m5-check/m5-image-check.mdx`,
  `m5-valid.md`, and `m5-broken.mdx`; links, headings, code fences, in-scope images, MDX
  placeholders, and broken-MDX fallback behavior were observed.
- Two minimal fixes were made during this sweep: the main workspace shell now uses a stable
  sidebar/detail `HStack` to avoid the AppKit constraint-loop crash seen during launch, and optional
  Open Recent persistence failures refresh recents without presenting a blocking error over an
  otherwise opened document. A regression test covers the Open Recent failure path.
- Remaining unchecked items are not assumed to pass. The manual broken-MDX edit/reintroduce loop
  and the MDX completion popup UI still need live editor-input validation; local automation could
  focus and scroll the STTextView editor but could not reliably synthesize typed input into it.

## Setup

- [x] Run `make preview-bundle` after any `preview-src/` change and confirm the committed preview bundle is current. Passed in this sweep; no bundle diff.
- [x] Run `make build`. Passed in this sweep.
- [x] Run `make test`. Passed in this sweep.
- [x] Launch Plainsong from the current branch. Current DerivedData build launched and opened the disposable workspace.
- [x] Open a folder workspace containing `Fixtures/` or copies of the M5 fixtures. Opened `/tmp/plainsong-m5-checklist/Fixtures`.
- [x] Ensure the preview pane is visible. Preview pane was toggled visible and observed.

## M4 Sequencing Gate

- [x] Confirm M4 remains accepted: completion, the Yams-backed frontmatter panel, smart paste, drag-in image handling, table helper, editing behaviors, and format commands still pass their tests/checklist. Covered by `make test` in this sweep, including MarkdownCore, EditorKit, WorkspaceKit, and app tests.
- [x] Confirm any new M5 work does not silently reopen M4 scope. This sweep adds only minimal
  checklist fixes for launch stability and optional recent-item persistence, plus docs/status
  updates; no new product features were added.

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
- [x] Confirm source-line anchors remain good enough for editor-to-preview scroll sync. `data-line` coverage passed in preview-src tests; PR #29 fixed the editor-to-preview source-line bridge with EditorKit regression coverage, and the current sweep kept those checks passing.

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
- [x] Confirm the preview bridge remains live: switching from the broken fixture to another valid Markdown/MDX file renders normally. Switched from `mdx-syntax-error.mdx` to `kitchen-sink.md` and `product-page.mdx`; both rendered current-document previews instead of stranding on the broken file.
- [ ] Edit the broken fixture into valid MDX and confirm the preview recovers without relaunching. Covered by preview-src test `surfaces syntax errors without blanking and recovers after a fix`, but not completed manually in the app because local automation could not synthesize editor text input into the live STTextView buffer.
- [ ] Reintroduce a syntax error and confirm the last good render remains visible where possible. Initial broken-file and rapid-switching paths showed last-good render fallback, but this specific in-editor edit/reintroduce loop was not completed manually for the same editor-input limitation.

## MDX Editor Source Experience

- [x] Open `Fixtures/product-page.mdx`. Opened in the disposable fixture workspace.
- [x] Confirm top-level `import` lines are visually distinct from prose. Observed in the current-build editor.
- [x] Confirm multiline JSX blocks are visually distinct from Markdown body text. Observed in `product-page.mdx`.
- [x] Confirm self-closing JSX components and closing tag lines are styled consistently. Observed in `product-page.mdx` / `kitchen-sink.mdx`; EditorKit highlighting tests also passed.
- [x] Confirm fenced `tsx` code retains code-fence highlighting behavior. Observed and covered by EditorKit tests.
- [x] Confirm ordinary `.md` files still use Markdown highlighting and are not treated as MDX. Observed `Fixtures/kitchen-sink.md` with Markdown badge; EditorKit tests also passed.
- [ ] M4 completion re-verification: Type `<` in an `.mdx` file with imports and confirm imported component completions appear. Completion engine/workspace tests passed, but the UI completion popup was not manually rechecked because local automation could not synthesize typed input into the live editor.
- [ ] M4 completion re-verification: Confirm MDX component completion does not appear inside obvious non-tag contexts such as fenced code blocks. Engine tests passed, but the UI completion popup was not manually rechecked for the same reason.

## Settings And Themes

M5 #16 scope covers built-in editor/preview themes and preference wiring. Custom editor-theme JSON
files and user CSS overrides are deferred by Decision Log until separate import/sanitizer designs
exist.

- [x] Open Settings and confirm it is no longer a placeholder. Manually opened Settings on 2026-06-25; General, Editor, Preview, and Files panes were visible, with General controls for default folder and autosave interval.
- [x] Change the General default folder and confirm the configured folder is used by default-folder workflows. Changed the default folder through Settings; the subsequent default-folder Open panel opened at the configured folder.
- [x] Change the General autosave interval and confirm autosave behavior follows the configured interval. Changed the interval to 1.5 s and confirmed a dirty document edit was persisted by autosave.
- [x] Change editor font family and confirm the active editor updates without reopening the file. Changed the live editor to Menlo and observed the active editor update without reopening.
- [x] Change editor font size and confirm the active editor updates without reopening the file. Changed the live editor from 13 pt to 14 pt and observed the active editor update without reopening.
- [x] Toggle line numbers and confirm the active editor updates. Toggled line numbers off and observed the active editor gutter disappear.
- [x] Toggle typewriter sync and confirm editor/preview scroll sync behavior updates immediately. The Settings toggle updated the running scroll coordinator immediately through `WorkspaceWindow.onChange`; the preference changed live without relaunch. Core editor-to-preview scroll sync remains covered by PR #29's manual and automated checks.
- [x] Confirm the two built-in editor themes are available. Covered by PR #26 EditorKit tests.
- [x] Confirm custom editor-theme JSON files remain deferred by Decision Log and are not exposed as incomplete UI. Deferred in `agent.md` Decision Log and §11.
- [x] Change editor theme or appearance and confirm syntax colors update without affecting typing responsiveness. Changed the editor theme to Graphite and observed syntax colors update in the active editor; existing typing/performance tests still passed.
- [x] Change preview theme to light and dark and confirm preview colors update independent of the OS appearance. Changed Preview theme between Dark and Light and observed preview colors update independently of the OS appearance.
- [x] Confirm user CSS overrides remain deferred by Decision Log and are not exposed as incomplete UI. Deferred in `agent.md` Decision Log and §11.
- [x] Confirm Mermaid output follows the selected preview theme. Opened `mermaid-theme.md`; Mermaid output changed with the selected preview dark/light theme.
- [x] With remote images disabled, confirm `https:` preview images are blocked by the default image policy. Covered by PR #26 preview-src tests and re-run by this sweep.
- [x] Enable Allow Remote Images and confirm `https:` preview images load without allowing other remote script/style loads. Covered by PR #26 preview-src tests and CSP policy; not visually rechecked.
- [x] Change the image-paste asset-folder pattern and confirm pasted images are stored under the configured folder. Covered by PR #26 app tests.
- [x] Change the default file extension between `.md` and `.mdx` and confirm new files use the selected extension. Covered by PR #26 app tests.
- [x] Quit and relaunch, then confirm settings persist. Relaunched Plainsong and confirmed Menlo, 14 pt, line numbers off, typewriter sync off, Graphite editor theme, Light preview theme, and 1.5 s autosave persisted.

## App Icon And Polish

- [x] Build and launch the app from Finder or Xcode. Built and launched current DerivedData app.
- [x] Confirm the Dock/app switcher icon is the Plainsong icon, not the generic placeholder. Bundle metadata points to `AppIcon`, `AppIcon.icns` is present, the extracted icon is the Plainsong mark, and the Dock showed that same Plainsong icon while the app was active.
- [x] Confirm the app accent color appears in standard controls where applicable. Observed in the current-build main window and backed by `NSAccentColorName`.
- [x] Confirm the main window, settings window, editor, and preview remain visually coherent in light and dark appearances. Main window, Settings window, editor, and preview were observed in light and dark appearances; the selected Light preview theme remained light under OS dark mode by design.

## Real Content Folder Acceptance

- [x] Open a representative Astro or Next.js content folder containing multiple `.mdx` posts. Opened `/tmp/plainsong-m5-real-next`, a representative Next.js-style content folder with `.md`, valid `.mdx`, broken `.mdx`, and an inline in-scope body image.
- [x] Open every `.mdx` post in that folder. Opened the valid MDX image fixture and the broken MDX switch target.
- [x] Confirm each post renders non-blank preview content. Valid MDX rendered nonblank content; broken MDX showed an error banner with last-good preview content instead of a blank preview.
- [x] Confirm imports/exports/components are represented as placeholders rather than executed. The real-content MDX component rendered as a non-executed placeholder; import/export behavior remains covered by fixtures and preview-src tests.
- [x] Confirm links, images that are within the granted folder scope, headings, and code fences behave as expected. Observed the heading, relative link, inline in-scope PNG body image, fenced code block, and MDX component placeholder in preview.
- [x] Switch rapidly between `.md`, `.mdx`, and broken `.mdx` files and confirm the preview never strands on the previous document. Rapidly switched between `m5-valid.md`, `m5-image-check.mdx`, and `m5-broken.mdx`; each transition updated the current document preview/error state without stranding on the prior document.

## Performance Acceptance

Record results in `docs/perf-log.md` before accepting M5.

- [x] Typing latency remains below 16 ms on `Fixtures/large-1mb.md`. Current sweep max was 0.465 ms.
- [x] Highlight update for visible range remains below 50 ms with visible-range plumbing/instrumentation in place; do not count the current 250 KB inline cutoff as passing. Current sweep max was Markdown 20.828 ms, MDX 22.468 ms.
- [x] Preview render for a 100 KB document remains below 100 ms after the normal debounce. Current sweep medians were Markdown 66.493 ms, MDX 17.177 ms.
- [x] Opening a 500 KB Markdown document reaches first paint below 300 ms. Current sweep value was 40.177 ms.
- [x] Host-process RSS remains below 400 MB with 8 warm sessions and 2 settled live webviews; record WebKit helper RSS as diagnostic if available, and do not count a single-webview path as passing. Current sweep reported 106.9 MB host RSS; WebKit helper aggregate 613.6 MB remained diagnostic only.
