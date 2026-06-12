# agent.md — BlogEditor (Native macOS Markdown/MDX Editor)

> **Read this file fully before writing any code.** It is the single source of truth for
> architecture, conventions, and roadmap. If you (an LLM agent or human) make a decision
> that contradicts or extends this document, update the **Decision Log** at the bottom in
> the same commit.

---

## 1. Project Overview

**BlogEditor** is a native macOS Markdown editor written in Swift, in the spirit of Typora,
optimized for blog authoring workflows (`.md` and `.mdx` files, YAML frontmatter, folder-based
projects such as Astro/Next.js content directories).

### Goals

- Native macOS app (Swift + SwiftUI shell + AppKit text engine). No Electron, no Catalyst.
- First-class editing of `.md`, `.markdown`, `.mdx` files.
- Live preview rendered side-by-side with synchronized scrolling (Phase 1), evolving into
  Typora-style in-place WYSIWYG rendering (Phase 2, see §13).
- Syntax highlighting in the editor (markdown structure + embedded code blocks + JSX in MDX).
- Context-aware autocompletion (snippets, link paths, fence languages, frontmatter keys).
- Open a single file *or* a folder workspace with a file-tree sidebar.
- Fast: instant typing latency on documents up to ~1 MB; preview updates < 150 ms debounced.

### Non-Goals (for now)

- iOS/iPadOS version (keep core packages platform-portable, but do not build UI for it).
- Cloud sync, accounts, collaboration.
- Full MDX component *execution* with user project bundling (placeholder rendering instead; see §9).
- Plugin system for third parties.

### Locked Product Decisions

| Decision | Choice |
|---|---|
| Editing model | Phase 1: two-pane source + live preview. Phase 2: Typora-style WYSIWYG. |
| File handling | Both single-file open and folder workspace with sidebar. |
| Preview technology | Native AppKit/TextKit 2 editor + `WKWebView` preview running a local JS pipeline. |
| Documentation language | English (this file). |
| Min deployment target | macOS 14 (Sonoma). |
| UI framework | SwiftUI app shell; AppKit (`NSViewRepresentable`) for the text editor. |

---

## 2. Tech Stack

| Layer | Technology | Notes |
|---|---|---|
| Language | Swift 5.10+ (enable strict concurrency; migrate to Swift 6 language mode when all deps allow) | |
| UI shell | SwiftUI (windows, sidebar, settings, toolbars) | |
| Text editor | [STTextView](https://github.com/krzyzanowskim/STTextView) (TextKit 2, AppKit) wrapped in `NSViewRepresentable` | Actively maintained; provides line numbers, plugins, completion window. Keep it behind our own `MarkdownEditorView` abstraction so it can be swapped for raw `NSTextView`+TextKit 2 if needed. |
| Syntax highlighting | [Neon](https://github.com/ChimeHQ/Neon) + [SwiftTreeSitter](https://github.com/tree-sitter/swift-tree-sitter) | Incremental, async highlighting. |
| Grammars | `tree-sitter-markdown` (block) + `tree-sitter-markdown-inline`, with injections: yaml (frontmatter), html, tsx (MDX/JSX regions), plus common fence languages (swift, js, ts, tsx, python, bash, json, css, html, yaml, go, rust) | Grammars vendored as SPM targets (each grammar repo ships an SPM package, or we wrap the C source). |
| Structure parsing (outline, etc.) | Reuse the tree-sitter syntax tree. Optionally [swift-markdown](https://github.com/swiftlang/swift-markdown) for export tasks. | Avoid two parsers driving the same UI. |
| Preview | `WKWebView` + local JS bundle built with **esbuild** from `preview-src/` | No remote network access by default (strict CSP). |
| Preview JS pipeline | unified: `remark-parse`, `remark-gfm`, `remark-frontmatter`, `remark-math`, `remark-mdx` (mdx only) → `rehype`, `rehype-katex`, `highlight.js` for fences; `mermaid` for ```mermaid fences; `morphdom` for incremental DOM patching | unified/remark is the standard 2026 pipeline and the only realistic path to MDX support. |
| Persistence of prefs | `UserDefaults` + JSON theme files in Application Support | |
| Project generation | **XcodeGen** (`project.yml` committed; `.xcodeproj` is generated, never hand-edited) | pbxproj diffs are hostile to LLM collaboration. |
| Lint/format | SwiftFormat + SwiftLint (configs committed) | |
| JS tooling | Node 20+, npm, esbuild, vitest (preview pipeline unit tests) | |

**Dependency policy:** keep the dependency list short. Adding any new Swift package or npm
package requires a Decision Log entry explaining why.

---

## 3. Repository Layout

```
blogeditor/
├── agent.md                  # ← this file
├── project.yml               # XcodeGen manifest (source of truth for the Xcode project)
├── Makefile                  # bootstrap / generate / build / test / preview-bundle
├── App/                      # Thin app target (SwiftUI)
│   ├── BlogEditorApp.swift   # @main, WindowGroup, Settings scene
│   ├── AppState.swift        # open workspaces, recent items
│   ├── Views/                # SwiftUI views: WorkspaceWindow, Sidebar, EditorSplit, StatusBar, FrontmatterPanel
│   └── Resources/            # Assets, preview dist bundle (generated), themes
├── Packages/
│   ├── MarkdownCore/         # Pure logic: document model, markdown utilities, completion engine, scroll-sync mapping. No AppKit/SwiftUI imports. Testable via `swift test`.
│   ├── EditorKit/            # STTextView wrapper, Neon/tree-sitter setup, editing behaviors (AppKit)
│   ├── PreviewKit/           # WKWebView controller, JS bridge, asset URL scheme handler
│   └── WorkspaceKit/         # File tree model, FS watching, security-scoped bookmarks, atomic save
├── preview-src/              # JS/TS source for the preview pipeline (npm workspace)
│   ├── package.json
│   ├── src/index.ts          # bridge protocol impl, render(), morphdom patching, scroll sync
│   ├── src/pipeline.ts       # unified pipeline (md and mdx variants)
│   ├── src/styles/           # preview CSS themes (github-light/dark, etc.)
│   └── test/                 # vitest specs
└── .github/workflows/ci.yml  # macOS runner: swiftformat --lint, swiftlint, swift test, xcodebuild test, npm test
```

Build artifacts: `preview-src` builds to `App/Resources/preview/` (`index.html`, `bundle.js`,
`bundle.css`). The dist output **is committed** so Swift-only agents can build the app without
Node installed; regenerate with `make preview-bundle` whenever `preview-src/` changes.

---

## 4. Architecture

```
┌────────────────────────── SwiftUI App Shell ──────────────────────────┐
│  WorkspaceWindow                                                      │
│  ┌──────────┐  ┌─────────────────────────┐  ┌──────────────────────┐  │
│  │ Sidebar  │  │  EditorPane (AppKit)    │  │  PreviewPane         │  │
│  │ FileTree │  │  STTextView + Neon      │  │  WKWebView + bridge  │  │
│  └────┬─────┘  └───────────┬─────────────┘  └──────────┬───────────┘  │
│       │                    │                           │              │
│  WorkspaceKit         EditorKit                   PreviewKit          │
│       └────────────┬───────┴───────────────┬──────────┘               │
│                    ▼                       ▼                          │
│              MarkdownCore (document model, completion, sync map)      │
└───────────────────────────────────────────────────────────────────────┘
```

### Data flow (Phase 1)

1. `DocumentSession` (MarkdownCore) owns the canonical text (`String` + version counter)
   for one open file.
2. Editor edits → `DocumentSession.apply(edit)` → publishes change (Combine/AsyncStream).
3. Neon receives incremental edit ranges → tree-sitter re-parse → highlight attributes
   applied asynchronously to visible range.
4. A debounced (150 ms) subscriber sends `{text, version, fileKind, baseURL}` to the
   preview via the JS bridge. JS renders HTML, patches DOM with morphdom, reports back
   `renderComplete(version)`.
5. Scroll sync uses line ↔ DOM node mapping (§8).
6. Autosave: debounced 1 s after last edit + on window resign; atomic write via
   `Data.write(.atomic)`; file watcher suppresses self-triggered events by comparing
   content hash.

### Key types (initial sketch — keep names)

- `DocumentSession` — open file: text, version, undo coordination, dirty state, encoding.
- `Workspace` — root folder URL, file tree snapshot, watcher, bookmark data.
- `EditorController` (EditorKit) — owns STTextView, applies behaviors, exposes
  `onTextChange`, `onSelectionChange`, `visibleLineRange`.
- `PreviewController` (PreviewKit) — owns WKWebView, queues render requests, drops stale
  versions, handles bridge messages.
- `CompletionEngine` (MarkdownCore) — pure function: `(text, cursorOffset, context) -> [Completion]`.
- `SyncMap` (MarkdownCore) — source line → preview anchor id mapping helpers.

### Concurrency rules

- UI mutation on `@MainActor` only.
- tree-sitter parsing and highlight query execution off main thread (Neon handles this; do
  not block its callbacks).
- Preview render requests are coalesced: only the latest version may be in flight; stale
  `renderComplete` responses are ignored.
- No `DispatchQueue.global` ad-hoc usage in new code; use structured concurrency (`Task`,
  actors) except where AppKit delegates force otherwise.

---

## 5. File & Workspace Handling

- **App Sandbox: ON.** All file access via user-selected URLs; persist
  security-scoped bookmarks for recents/workspaces; always wrap access in
  `startAccessingSecurityScopedResource()` pairs (helper in WorkspaceKit).
- Open single file: standard `NSOpenPanel` / drag onto Dock / Finder "Open With"
  (import-declare `net.daringfireball.markdown`, and export a UTI for `.mdx`:
  `com.blogeditor.mdx` conforming to `public.plain-text` — the `public.*` namespace
  is reserved for Apple).
- Open folder: sidebar shows the tree; filter to show only markdown-related files by
  default (`.md`, `.markdown`, `.mdx`), toggle "Show all files". Images shown so they can
  be drag-inserted.
- File tree operations: create/rename/delete/move file & folder (Finder-style, with
  trash not hard delete). Watch root recursively via `FSEventStream`; debounce 300 ms;
  reconcile tree diff instead of full reload to preserve expansion state.
- External change to the open file: if editor is clean → silently reload; if dirty →
  non-modal banner "File changed on disk: Reload / Keep mine".
- Multiple workspace windows allowed; one preview per editor pane.
- Tabs: native window tabs (`NSWindow.tabbingMode`) deferred; Phase 1 uses sidebar
  selection to switch the single editor pane (like Typora). Multiple open
  `DocumentSession`s kept warm in an LRU (max 8) so switching files is instant.

---

## 6. Editor (EditorKit)

### 6.1 Base component

`STTextView` (AppKit, TextKit 2) hosted in `NSViewRepresentable` (`MarkdownEditorView`).
Configure: line numbers gutter (toggleable), invisible characters off, wraps lines,
variable-width font allowed (default: SF Mono 13 for source mode).

**Abstraction rule:** App/ and MarkdownCore/ must never import STTextView types. Only
EditorKit knows the concrete editor. This keeps the Phase-2 WYSIWYG swap and any library
replacement local to EditorKit.

### 6.2 Syntax highlighting

- Neon `TextViewHighlighter` (or its TextKit-2 system interface) drives incremental
  highlighting from tree-sitter.
- Two-layer markdown grammar: `markdown` (block structure) with `markdown-inline`
  injected, then language injections inside fenced code blocks keyed by the info string.
- Frontmatter: the markdown grammar exposes the YAML frontmatter block → inject
  `tree-sitter-yaml`.
- `.mdx` files: tree-sitter has no mature MDX grammar. Strategy: parse with the markdown
  grammar; add custom injection queries that route `html_block` / `html_inline` nodes and
  top-level `import`/`export` lines to the `tsx` grammar. This yields good-enough JSX
  highlighting. Known limitation: multiline JSX expressions containing blank lines may
  mis-highlight — acceptable for Phase 1; revisit with a dedicated MDX grammar later.
- Theme: semantic capture names (`@markup.heading`, `@markup.bold`, `@string`,
  `@keyword`, …) mapped to a `EditorTheme` struct (colors + font traits). Ship
  `default-light` and `default-dark`, follow system appearance.
- Style targets in source mode (Typora-like source styling): headings bold & scaled
  slightly, bold/italic spans rendered with the actual trait, inline code with background
  pill, links colored, fence blocks with subtle background band.

### 6.3 Editing behaviors (all in EditorKit, unit-test the pure parts in MarkdownCore)

- **List continuation:** Enter inside `-`/`*`/`1.`/`- [ ]` list inserts next marker
  (renumbering ordered lists); Enter on an empty item removes the marker (exits list).
  Tab / Shift-Tab indents/outdents list items.
- **Auto-pairing:** `**`, `*`, `_`, `` ` ``, `(`, `[`, `{`, `"`, `<` (mdx). Wrapping: with a
  selection, typing a pair character wraps the selection. Skip-over on closing char.
- **Code fence helper:** typing ``` ``` ``` then Enter auto-inserts closing fence and places
  cursor inside; language autocomplete fires after the opening fence.
- **Smart paste:** pasting a URL over selected text creates `[selection](url)`. Pasting an
  image from clipboard saves it to `assets/` (configurable, relative to the file) and
  inserts `![](path)`. Drag-in image files insert relative-path links (copy into
  `assets/` if outside the workspace).
- **Table helper:** Tab/Shift-Tab navigate cells; Enter adds a row; `Format Table`
  command (⌥⌘F) realigns pipes. Pure formatting function lives in MarkdownCore.
- **Checkbox toggle:** ⌘L toggles `- [ ]`/`- [x]` on current line(s).

### 6.4 Formatting commands & shortcuts

| Command | Shortcut | Behavior (toggle, selection-aware) |
|---|---|---|
| Bold | ⌘B | `**…**` |
| Italic | ⌘I | `*…*` |
| Strikethrough | ⌃⌘X | `~~…~~` |
| Inline code | ⌘E | `` `…` `` |
| Link | ⌘K | `[sel](cursor)` |
| Heading 1–6 | ⌘1…⌘6 | replace line prefix |
| Paragraph | ⌘0 | strip heading prefix |
| Quote | ⌘⇧Q | toggle `> ` |
| Code fence | ⌘⇧K | wrap selection in fences |
| Toggle preview pane | ⌘⇧P | show/hide right pane |
| Toggle sidebar | ⌘⇧S (or native ⌃⌘S) | |
| Format table | ⌥⌘F | |
| Toggle checkbox | ⌘L | |

All commands appear in the menu bar (Format menu) — menu first, shortcut second, so they
are discoverable and scriptable.

### 6.5 Completion engine

UI: STTextView's completion window (or custom NSPanel if insufficient). Trigger: typing
the trigger characters below, or ⌃Space manually. Engine is pure Swift in MarkdownCore:
`complete(text:cursor:workspace:) -> [Completion]` — fully unit-tested.

| Context | Trigger | Completions |
|---|---|---|
| Line start | typing `#`, `>`, `-` … | snippet list: headings, table skeleton, fenced block, task item, frontmatter block (only at file top) |
| After ```` ``` ```` | fence info | language ids (`swift`, `ts`, `python`, `mermaid`, …) |
| Inside `](` or `](./` | `(`, `/` | workspace-relative file paths (md files and images), anchors `#heading` within current file |
| Inside `![](` | `(` | image files in workspace |
| `:` + 2 chars | `:` | emoji shortcodes → insert unicode |
| Frontmatter block | line start | keys: `title`, `description`, `date`, `tags`, `draft`, `slug` + keys learned from sibling files in workspace |
| `.mdx` after `<` | `<` | component names found via regex-scan of `import` lines in the current file (Phase 1 scope) |

Ranking: prefix match > fuzzy; recently used boosted. Max 50 items. Never block typing —
compute async, cancel stale requests.

---

## 7. Preview (PreviewKit + preview-src)

### 7.1 Web view setup

- One `WKWebView` per editor pane, non-opaque, loads the bundled `index.html` once and
  stays alive (re-render via JS, never reload the page per keystroke).
- **Security:** strict CSP (`default-src 'none'; script-src 'self'; style-src 'self'
  'unsafe-inline'; img-src asset: data:`), `isElementFullscreenEnabled` off, no remote
  loads by default. A user preference can later allow `https:` images.
- **Local assets:** custom scheme `asset://` via `WKURLSchemeHandler`. JS rewrites
  relative image/link `src` to `asset://<workspace-relative-path>`; the handler resolves
  against the current file's directory / workspace root, enforces path containment
  (reject `..` escapes outside the workspace), streams the file.
- Link clicks: intercepted in Swift. `http(s)` → `NSWorkspace.open` (external browser).
  Relative `.md`/`.mdx` → open that file in the editor. `#anchor` → scroll preview.

### 7.2 JS pipeline (preview-src)

Two unified pipelines selected by `fileKind`:

- `md`: `remark-parse` → `remark-gfm` → `remark-frontmatter` → `remark-math` →
  `remark-rehype` → `rehype-katex` → custom rehype plugin `rehype-source-lines` (adds
  `data-line` from AST `position` to block elements) → `rehype-stringify`.
- `mdx`: same + `remark-mdx`; a custom remark plugin transforms `mdxJsxFlowElement` /
  `mdxJsxTextElement` / `mdxjsEsm` nodes into placeholder HTML (§9) instead of compiling.

Post-render in browser: `highlight.js` on code fences (langs registered explicitly,
~20 common ones); `mermaid.render` for `mermaid` fences (init once, theme follows app);
checkbox inputs enabled and clickable.

DOM update: render to HTML string → `morphdom` patch against live DOM. This preserves
scroll position, mermaid SVGs (keyed by content hash to skip re-render), and image loads.

Frontmatter is **not** rendered as a table in the preview body; it is stripped (shown in
the Frontmatter panel, §10). Optional toggle to show it as a styled block.

### 7.3 Swift ↔ JS bridge protocol

`window.webkit.messageHandlers.bridge.postMessage(...)` (JS→Swift) and
`webView.evaluateJavaScript("render(payloadJSON)")` (Swift→JS). Keep the protocol in one
Swift file (`BridgeMessage.swift`, Codable) and one TS file (`bridge.ts`) — **these two
must be kept in sync; both list message names in the same order with a
`PROTOCOL_VERSION` constant checked at `ready`.**

| Direction | Message | Payload |
|---|---|---|
| JS→Swift | `ready` | `{protocolVersion}` |
| Swift→JS | `render` | `{version, fileKind, text, baseDir, theme}` |
| JS→Swift | `renderComplete` | `{version, blockCount}` |
| Swift→JS | `scrollToLine` | `{line, animated}` |
| JS→Swift | `previewScrolled` | `{topVisibleLine}` (only while preview owns scroll) |
| JS→Swift | `linkClicked` | `{href}` |
| JS→Swift | `checkboxToggled` | `{line, checked}` → Swift edits source text |
| Swift→JS | `setTheme` | `{theme}` |

### 7.4 Build

`make preview-bundle`: `npm ci && esbuild src/index.ts --bundle --minify` →
`App/Resources/preview/`. KaTeX fonts/CSS, highlight.js theme CSS, mermaid bundled
locally. No CDN, app must work fully offline. Commit the dist output.

---

## 8. Scroll Sync

Mapping basis: `data-line` attributes emitted by `rehype-source-lines` on every
block-level element.

- **Editor → preview (primary direction):** on editor scroll, compute first visible
  source line (TextKit 2 `textLayoutManager` viewport) → `scrollToLine`. JS finds the
  nearest `[data-line]` ≤ line and the next one > line, interpolates between their
  `offsetTop`s proportionally to line distance → smooth, accurate positioning.
- **Preview → editor:** symmetric, using `previewScrolled`.
- **Loop prevention:** a `scrollOwner` token (`editor` | `preview` | `none`) with 100 ms
  decay; messages from the non-owner are dropped.
- Cursor-follow option: "typewriter sync" — on text edit, preview scrolls to the edited
  line (on by default, like Typora).

---

## 9. MDX Support — Scope and Phasing

`.mdx` = Markdown + ESM imports/exports + JSX. Full fidelity requires a JS bundler with
the user's project dependencies — out of scope. Defined behavior:

**Phase 1 (required):**

- Editor: highlight JSX/ESM regions via tsx injection (§6.2). Completion for component
  names from `import` lines.
- Preview: `remark-mdx` parses; custom plugin renders:
  - `mdxjsEsm` (import/export) → collapsed chip row, e.g. `⟨import Button from
    '../components'⟩`, monospace, dimmed.
  - JSX elements → a "component card": bordered box, header = component name + key props
    (stringified, truncated), body = rendered markdown children if any. Lowercase HTML
    elements (`<div>`, `<img>`) render as real HTML (sanitized).
  - `{expression}` inline → rendered as code chip with the raw expression.
- Parse errors (MDX is stricter than MD): show inline error banner in preview with line
  number; editor keeps last good render below the banner. Never blank the preview while
  typing through transient syntax errors — keep last good DOM and show a subtle
  "stale/error" indicator instead.

**Phase 3+ (optional, not scheduled):** real component rendering via `@mdx-js/mdx`
in-browser compile + user-supplied component map. Requires design for sandboxing — do not
attempt without a Decision Log entry.

---

## 10. Frontmatter Panel

- Detect YAML frontmatter (`---` fences at byte 0). Parse with `Yams` (SPM).
- Sidebar-attached collapsible form panel: key/value editing with type-aware controls
  (string, date picker for `date`, tag token field for `tags`, toggle for `draft`).
- Edits write back into the source text (panel ↔ text always derived from the document;
  the text is the single source of truth).
- Malformed YAML → panel shows raw text + error, never crashes, never rewrites what it
  cannot parse.

---

## 11. Theming & Settings

- **Editor themes:** JSON files (capture name → color/traits), in Application Support;
  two built-ins. Live-switch with system appearance.
- **Preview themes:** CSS files paired with editor themes (`github-light`, `github-dark`
  defaults). User CSS override file supported (loaded after theme).
- **Settings window (SwiftUI `Settings` scene):** General (default folder, autosave
  interval), Editor (font, size, line numbers, typewriter sync), Preview (theme, allow
  remote images), Files (image-paste asset folder pattern, default extension `.md`/`.mdx`).

---

## 12. Performance Requirements

| Metric | Budget |
|---|---|
| Keystroke → screen (typing latency) | < 16 ms (never block main thread on parse) |
| Highlight update after edit | < 50 ms visible range, async |
| Preview update (debounced) | render < 100 ms for 100 KB doc; debounce 150 ms |
| File open (500 KB md) | < 300 ms to first paint, highlight may stream in |
| Memory | < 400 MB with 8 warm sessions + 2 webviews |

Techniques: tree-sitter incremental edits (`InputEdit`), Neon visible-range-first
highlighting, morphdom patching, render-version dropping, LRU sessions, mermaid memoization
by fence content hash. **Any PR that regresses typing latency is rejected regardless of
features.** Add a `PerformanceTests` target with a large fixture (`Fixtures/large-1mb.md`).

---

## 13. Phase 2 — Typora-Style WYSIWYG (design sketch, do not build during Phase 1)

Approach: stay on TextKit 2 (no contentEditable). The source text remains the model; the
editor *folds* markdown tokens via rendering, not text mutation:

- Parse → for each inline/block node, when the selection/cursor is **outside** the node,
  apply "rendered" presentation: hide delimiter tokens (zero-width via TextKit 2 layout
  fragment customization or attribute folding), apply real styles (heading size, bold,
  italic), replace image links with `NSTextAttachment` thumbnails, render fences with a
  framed code block (custom `NSTextLayoutFragment`).
- When the cursor enters a node's range → reveal raw markdown for that node only
  (Typora's behavior).
- Tables and mermaid in WYSIWYG: custom layout fragments embedding views — hardest part;
  tables may initially stay raw with the table helper (§6.3).
- Undo, IME composition (Chinese input!), and selection across folded tokens are the risk
  areas — write exploratory tests early. **IME correctness is non-negotiable: test with
  Traditional Chinese (Zhuyin/Pinyin) marked text at every change.**
- The two-pane mode remains available behind a toggle forever (⌘⇧P cycles: source+preview
  / source only / WYSIWYG once it ships).

Phase 2 begins only when Milestones M1–M5 are complete and a dedicated design doc
(`docs/wysiwyg-design.md`) is approved.

---

## 14. Roadmap & Milestones (Phase 1)

Work strictly in order; each milestone has acceptance criteria that must pass before the
next begins.

### M0 — Scaffold
- XcodeGen `project.yml`, app target + 4 local SPM packages, Makefile, CI workflow,
  SwiftFormat/SwiftLint configs, this file.
- ✅ Accept: `make generate && make build` succeeds; empty window launches; `swift test`
  runs (even with 0 tests); CI green.

### M1 — Editor core
- STTextView wrapped, open/save single `.md` (sandbox + UTIs), autosave, dirty indicator,
  undo/redo, line numbers, word/char count in status bar.
- Temporary regex-based source styling is allowed only as a bridge to parser-backed
  highlighting; it must be debounced and must not synchronously re-highlight every
  keystroke. Documents above `MarkdownEditorView.maxComputedHighlightLength`
  (~200 KB UTF-8) enter large-document mode: bridge styling and the line-number
  gutter are disabled to keep typing latency flat; M1.5 removes this limit.
- ✅ Accept: open/save `Fixtures/kitchen-sink.md`; type at top of `large-1mb.md` with
  no visible lag from the fallback styling path; quit & relaunch restores last file.

### M1.5 — Parser-backed highlighting
- Neon + tree-sitter markdown highlighting incl. frontmatter-yaml and fence injections.
- ✅ Accept: open `Fixtures/kitchen-sink.md`, all constructs highlighted from the parser
  tree; type at top of `large-1mb.md` with no visible lag; fallback regex highlighter is
  removed or left only as an explicitly disabled emergency path.

### M2 — Live preview
- WKWebView + bundled pipeline (md only), bridge protocol, debounced incremental render,
  asset:// images, link handling, checkbox writeback, scroll sync both directions,
  KaTeX + mermaid + highlight.js working offline.
- Preview pane toggle: ⌘⇧P (and a toolbar button) switches between source-only and a
  side-by-side fully rendered pane ("Warp-style" final-render view, owner-requested).
  The chosen layout persists across relaunch.
- ✅ Accept: kitchen-sink renders correctly offline; ⌘⇧P shows/hides the rendered pane
  with the layout restored on relaunch; scroll sync drift < 1 viewport on a 10k-line
  doc; toggling a checkbox in preview edits the source line.

### M3 — Workspace
- Folder open, sidebar file tree (create/rename/delete/move, drag), FSEvents reconcile,
  LRU sessions, external-change banner, recents menu, security-scoped bookmark restore.
- ✅ Accept: edit files in Finder/git while app open — tree and open file stay correct;
  no bookmark prompts on relaunch.

### M4 — Authoring features
- Completion engine (all contexts in §6.5), editing behaviors (§6.3), formatting
  commands + menu (§6.4), smart paste/drag of images, frontmatter panel, table helper.
- ✅ Accept: unit tests cover every completion context and list/table behavior; manual
  script `docs/m4-checklist.md` passes.

### M5 — MDX + polish
- `.mdx` end-to-end: UTI, tsx-injection highlighting, mdx pipeline with placeholder
  components, error banner; themes + settings window; app icon; performance pass
  against §12 budgets.
- ✅ Accept: open a real Astro/Next.js content folder; every `.mdx` post renders without
  blanking; all §12 budgets measured and recorded in `docs/perf-log.md`.

**Phase 2 = WYSIWYG (§13). Phase 3 candidates:** export (HTML/PDF via preview print),
window tabs, search across workspace (ripgrep-style), publish integrations, real MDX
component rendering.

---

## 15. Build, Run, Tooling

```sh
make bootstrap        # brew install xcodegen swiftformat swiftlint node; npm ci (preview-src)
make generate         # xcodegen generate  (run after editing project.yml)
make preview-bundle   # build preview-src → App/Resources/preview/ (commit the output)
make build            # xcodebuild -scheme BlogEditor build
make test             # swift test (packages) + xcodebuild test + (cd preview-src && npm test)
make format           # swiftformat . && swiftlint --fix
```

- Xcode 16+. `.xcodeproj` is generated — **never hand-edit, never commit pbxproj
  conflicts; edit `project.yml`.**
- Code signing: "Sign to Run Locally" for dev; hardened runtime + notarization scripted
  later (Phase 3, direct distribution first, App Store optional).

---

## 16. Testing Strategy

- **MarkdownCore (highest coverage, pure Swift):** completion engine (table-driven tests
  per context), list continuation/renumber, table formatter, sync-map math, frontmatter
  parse/writeback. Target ≥ 90% on this package.
- **EditorKit:** behavior tests via programmatic `NSTextView` interaction where feasible;
  IME marked-text regression tests (insert Zhuyin composition, assert no corruption).
- **PreviewKit:** bridge protocol round-trip tests; path-containment tests for
  `asset://` handler (security-critical: `../../` must be rejected).
- **preview-src (vitest):** pipeline snapshot tests for kitchen-sink.md and mdx fixtures;
  `data-line` presence; placeholder rendering of MDX nodes.
- **Fixtures:** `Fixtures/kitchen-sink.md` (every GFM construct + math + mermaid),
  `Fixtures/kitchen-sink.mdx`, `Fixtures/large-1mb.md` (generated, committed),
  `Fixtures/broken-frontmatter.md`, `Fixtures/mdx-syntax-error.mdx`.
- UI tests: minimal smoke (launch, open fixture, type, preview updates). Don't invest in
  brittle full UI automation.

---

## 17. Collaboration Rules for LLM Agents

1. **Read agent.md first.** If your task conflicts with it, stop and surface the conflict
   instead of silently diverging.
2. **Scope:** one milestone-task per session/PR. Do not start M(n+1) work inside M(n).
3. **Layering is law:** App → {EditorKit, PreviewKit, WorkspaceKit} → MarkdownCore.
   Lower layers never import higher ones; MarkdownCore imports no UI frameworks.
4. **Edit `project.yml`, never `.xcodeproj`.** Run `make generate` after.
5. **Bridge changes:** any change to `BridgeMessage.swift` requires the mirrored change in
   `bridge.ts`, a `PROTOCOL_VERSION` bump, and `make preview-bundle` in the same commit.
6. **Tests accompany logic.** New MarkdownCore/pipeline logic without tests is incomplete.
   Run `make test` and `make format` before declaring done.
7. **No new dependencies** (Swift or npm) without a Decision Log entry with rationale and
   alternatives considered.
8. **Performance budgets (§12) are gates**, not suggestions. When touching the edit path,
   state how you verified typing latency.
9. **Main-thread discipline:** parsing/rendering off main; UI on `@MainActor`. No new
   `DispatchQueue.global` calls.
10. **Naming/style:** Swift API Design Guidelines; SwiftFormat config is authoritative;
    no abbreviations in type names; files ≤ ~400 lines, split by extension/feature.
11. **Commits:** imperative subject, body explains *why*; reference milestone (e.g.
    `M2: add scroll owner arbitration`).
12. **When uncertain about UX,** match Typora's behavior first, macOS HIG second, then ask.
13. **Update documentation:** behavior changes → update relevant § here; architectural
    choices → Decision Log entry (date, decision, why, alternatives).

---

## 18. Decision Log

| Date | Decision | Rationale / Alternatives |
|---|---|---|
| 2026-06-12 | Two-pane first, WYSIWYG as Phase 2 | Ship value early; WYSIWYG on TextKit 2 is the highest-risk component. Alt: WYSIWYG-first (rejected: months before usable). |
| 2026-06-12 | STTextView over raw NSTextView | Line numbers, completion window, plugin points, active maintenance; M1 pins STTextView 2.3.10 exactly for deterministic builds. Wrapped behind EditorKit abstraction to keep swap cost low; alt raw NSTextView remains fallback if dependency risk grows. |
| 2026-06-12 | Neon + SwiftTreeSitter for highlighting | Incremental + async, proven in Chime/CodeEdit ecosystem. Alt: regex highlighting (rejected: wrong for nested fences), Highlightr (rejected: full-document re-highlight, no structure). |
| 2026-06-12 | Regex styling is a temporary M1 bridge, not final highlighting | Used to unblock editor-core integration while Neon/tree-sitter dependency shape is resolved. It must stay behind `MarkdownEditorView`/`MarkdownSyntaxHighlighter`, use cached regexes, and debounce full-document work. M1.5 owns replacing it with Neon + SwiftTreeSitter before preview/workspace milestones proceed. |
| 2026-06-12 | M1.5 uses a direct SwiftTreeSitter highlighter façade first | The parser-backed highlighter now consumes tree-sitter markdown + markdown-inline nodes and a wrapped YAML grammar target, removing the M1 regex fallback and large-document skip while keeping parsing off the main actor. Neon 0.6.0 currently depends on ChimeHQ/SwiftTreeSitter `main`, which conflicts with the official grammar packages in this repo; keep the EditorKit façade narrow so Neon/TextViewHighlighter can replace the mapper once the dependency graph is deterministic. |
| 2026-06-12 | WKWebView + unified/remark preview | Only realistic MDX path; KaTeX/mermaid free. Alt: full native rendering (rejected: MDX/math/diagrams cost). Editor stays native — app is not a web app. |
| 2026-06-12 | MDX components render as placeholder cards in Phase 1 | Real execution needs user project bundling + sandbox design. |
| 2026-06-12 | XcodeGen + committed preview dist | pbxproj and node_modules are hostile to LLM diff-based collaboration. |
| 2026-06-12 | App Sandbox on from day 1 | Retrofitting sandbox is painful; keeps App Store option open. |
| 2026-06-12 | macOS 14+ | TextKit 2 mature, modern SwiftUI APIs; Typora-class audience updates quickly. |
| 2026-06-12 | M0 ships with zero external Swift dependencies | First build must be deterministic; STTextView/Neon/grammars land in M1 with pinned versions. Packages use swift-tools 5.10 + StrictConcurrency experimental flag. |
| 2026-06-12 | Editor typing hot path moves plain `String` only | Per-keystroke String⇄NSAttributedString⇄AttributedString bridging of the whole document caused visible lag on 1 MB files. The editor binding carries `String`; highlight output flows separately as a revisioned `HighlightedText` (Equatable by revision), is computed on a detached task, and is applied via in-place `setAttributes`. Statistics are likewise computed off-main. This shape is also what M1.5's Neon integration needs. |
| 2026-06-12 | Keystrokes must not publish through the document model | Time Profiler showed per-key SwiftUI re-renders of the whole window (DynamicBody under `keyDown`) plus foreign-string traffic (`_StringGuts.foreign*`, CFStorage). `DocumentSession.text`/`version` are non-`@Published`; `isDirty` assignments are deduped; the coordinator eagerly `makeContiguousUTF8()`s the bridged string so downstream compares/counts run native. M2's preview must subscribe to text via its own debounced channel, not `objectWillChange`. |

---

## 19. Reference Links

- STTextView: https://github.com/krzyzanowskim/STTextView
- Neon: https://github.com/ChimeHQ/Neon
- SwiftTreeSitter: https://github.com/tree-sitter/swift-tree-sitter
- tree-sitter-markdown: https://github.com/tree-sitter-grammars/tree-sitter-markdown
- swift-markdown (export use): https://github.com/swiftlang/swift-markdown
- unified/remark: https://unifiedjs.com · remark-mdx: https://mdxjs.com/packages/remark-mdx/
- Yams (YAML): https://github.com/jpsim/Yams
- XcodeGen: https://github.com/yonaskolb/XcodeGen
- Typora (behavior reference): https://typora.io
