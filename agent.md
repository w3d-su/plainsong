# agent.md — Plainsong (Native macOS Markdown/MDX Editor)

> **Read this file fully before writing any code.** It is the single source of truth for
> architecture, conventions, and roadmap. If you (an LLM agent or human) make a decision
> that contradicts or extends this document, update the **Decision Log** at the bottom in
> the same commit.

---

## 1. Project Overview

**Plainsong** is a native macOS Markdown editor written in Swift, in the spirit of Typora,
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
| Persistence of prefs | `UserDefaults` + built-in theme IDs; custom theme/user CSS imports deferred | |
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
│   ├── PlainsongApp.swift   # @main, WindowGroup, Settings scene
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
  `app.plainsong.mdx` conforming to `public.plain-text` — the `public.*` namespace
  is reserved for Apple).
- Open folder: sidebar shows the tree; filter to show only markdown-related files by
  default (`.md`, `.markdown`, `.mdx`), toggle "Show all files". Images shown so they can
  be drag-inserted.
- File tree operations: create/rename/delete/move file & folder (Finder-style, with
  trash not hard delete). Watch root recursively via `FSEventStream`; debounce 300 ms;
  reconcile tree diff instead of full reload to preserve expansion state.
- External change to the open file: if editor is clean → silently reload; if dirty →
  non-modal banner "File changed on disk: Reload / Keep mine".
- Multiple workspace windows are structurally allowed, one preview per editor pane, but
  Phase 1 currently shares one App-scoped `AppState` across the `WindowGroup`. Separate
  windows mirror the same workspace/current document until window-scoped state is built.
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
  Tab / Shift-Tab indents/outdents list items, including every list item overlapped by
  a multi-line selection.
- **Auto-pairing:** `_`, `` ` ``, `(`, `[`, `{`, `"`, `<` (mdx) auto-close at the
  caret. `*` wraps a selection as italic (`*…*`) but does not auto-close at a bare
  caret so bullets and manually typed italics stay natural. Wrapping: with a selection,
  typing a pair character wraps the selection. Skip-over on closing char except for `*`.
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
| New file | ⌘N | workspace: dedup `Untitled.md` at root; single-file: save panel |

All commands appear in the menu bar (Format menu) — menu first, shortcut second, so they
are discoverable and scriptable. Format menu actions route through the AppKit responder
chain so commands apply to the focused editor in the key window; if focus is in the
sidebar or preview, the formatting command no-ops instead of falling back to another
editor.

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
  'unsafe-inline'; img-src asset: data: https:`), `isElementFullscreenEnabled` off, and
  no remote loads by default. The preview JS removes remote image `src` values unless
  the user enables the Allow Remote Images preference; that preference permits only
  `https:` images and does not relax script, style, navigation, or non-image network
  behavior.
- **Local assets:** custom scheme `asset://` via `WKURLSchemeHandler`. JS rewrites
  relative image/link `src` to `asset://<workspace-relative-path>`; the handler resolves
  against the current file's directory / workspace root, enforces path containment
  (reject `..` and symlink escapes outside the workspace), and serves only PNG, JPEG,
  GIF, or WebP assets up to 10 MiB. SVG and other active/ambiguous formats are rejected
  until a separate sanitization policy exists.
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
| Swift→JS | `render` | `{renderID, version, fileKind, text, baseDir, theme}`; `renderID` is a controller-assigned globally-monotonic stale-drop key (ordered across document switches); `version` is the per-document `DocumentSession.version` used only for `checkboxToggled` round-tripping; `baseDir` is the workspace-root-relative parent directory for the rendered file, or `null` for single-file/root renders |
| JS→Swift | `renderComplete` | `{renderID, version, blockCount}` |
| Swift→JS | `scrollToLine` | `{line, animated}` |
| JS→Swift | `previewScrolled` | `{topVisibleLine}` (only while preview owns scroll) |
| JS→Swift | `linkClicked` | `{href}` |
| JS→Swift | `checkboxToggled` | `{line, checked, version}` → Swift edits source text only when `version` matches the current document |
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
    elements (`<div>`, `<img>`) render as real HTML through the sanitizer, but inline
    `style`, event-handler attributes, scripts, `srcdoc`, and user-authored SVG are
    stripped or dropped.
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

- **Editor themes:** two built-ins wired through Settings and applied live. Custom JSON
  theme files in Application Support are deferred until a separate import/validation
  design exists.
- **Preview themes:** bundled CSS variables for system/light/dark preview themes, paired
  with the editor settings bridge. User CSS overrides are deferred until a separate
  sanitizer/design exists.
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
| Memory (app host RSS) | < 400 MB in the Plainsong host process with 8 warm sessions + 2 settled live WKWebViews |

Techniques: tree-sitter incremental edits (`InputEdit`), Neon visible-range-first
highlighting, morphdom patching, render-version dropping, LRU sessions, mermaid memoization
by fence content hash. **Any PR that regresses typing latency is rejected regardless of
features.** Add a `PerformanceTests` target with a large fixture (`Fixtures/large-1mb.md`).

M5 planning note: the highlight budget is accepted only from visible-range-first
highlighting instrumentation, not from the historical 250 KB full-document inline
parsing cutoff. The memory budget is scoped to deterministic app host-process RSS.
OS-managed WebKit helper processes should be recorded as diagnostic/informational
data because helper reuse and process-pool ownership vary across runs and CI hosts.

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

Phase 2 implementation begins only when Milestones M1-M5 are accepted and a dedicated
design doc (`docs/wysiwyg-design.md`) is approved.

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
- Known M2 limitation: in single-file mode under the app sandbox, the app only receives
  a security-scoped grant for the selected Markdown file. Sibling `asset://` images may
  fail until M3's folder workspace grants directory scope.

### M3 — Workspace
- Folder open, sidebar file tree (create/rename/delete/move, drag), FSEvents reconcile,
  LRU sessions, external-change banner, recents menu, security-scoped bookmark restore.
- ✅ Accept: edit files in Finder/git while app open — tree and open file stay correct;
  no bookmark prompts on relaunch.

### M4 — Authoring features
- Completion engine (all contexts in §6.5), editing behaviors (§6.3), formatting
  commands + menu (§6.4), smart paste/drag of images, frontmatter panel, table helper.
- M4 landed across review-sized PRs: editing behaviors, formatting commands, completion
  engine, frontmatter panel, smart paste, drag-in image handling, and table helper.
- ✅ Accept: unit tests cover every completion context and list/table behavior; manual
  script `docs/m4-checklist.md` passes.

### M5 — MDX + polish
- `.mdx` end-to-end: UTI, tsx-injection highlighting, mdx pipeline with placeholder
  components, error banner; themes + settings window; app icon; performance pass
  against §12 budgets.
- Current status: MDX preview, TSX highlighting, icon/accent, §12 performance
  measurements, PR #24/#27 security hardening, and PR #26 Settings/themes have landed.
  The 2026-06-25 final sweeps fixed scroll sync, launch/Open Recent, MDX error liveness,
  and live MDX completion-popup checklist blockers; M5 is **accepted** because
  `docs/m5-checklist.md` now passes.
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
make build            # xcodebuild -scheme Plainsong build
make test             # swift test (packages) + xcodebuild test + (cd preview-src && npm test)
cd preview-src && npm run typecheck  # preview TypeScript check; CI runs this separately
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
  `Fixtures/broken-frontmatter.md`, `Fixtures/mdx-syntax-error.mdx`,
  `Fixtures/product-page.mdx`, `Fixtures/perf-100kb.md`,
  `Fixtures/perf-500kb.md`.
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
14. **Branch + PR workflow (adopted after M2):** `main` is protected. Do all work on a
    branch named `m<N>-<slug>` (e.g. `m3-workspace`) and open a PR against `main`.
    State the branch name when you start. Never push to `main` directly, never create
    branches with other naming schemes, never force-push, and never merge your own PR —
    the maintainer merges (squash) after review and green CI. One milestone (or one
    review-fix batch) per PR.

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
| 2026-06-12 | Keep network-client entitlement for sandboxed WKWebView startup | App-hosted `PreviewController()` smoke test reproduced WebContent process launch failure without `com.apple.security.network.client` (`Application does not have permission to communicate with network resources`), leaving the pane blank before any remote request. Preview remains offline by CSP and bundled resources. |
| 2026-06-12 | macOS 14+ | TextKit 2 mature, modern SwiftUI APIs; Typora-class audience updates quickly. |
| 2026-06-12 | M0 ships with zero external Swift dependencies | First build must be deterministic; STTextView/Neon/grammars land in M1 with pinned versions. Packages use swift-tools 5.10 + StrictConcurrency experimental flag. |
| 2026-06-12 | Editor typing hot path moves plain `String` only | Per-keystroke String⇄NSAttributedString⇄AttributedString bridging of the whole document caused visible lag on 1 MB files. The editor binding carries `String`; highlight output flows separately as a revisioned `HighlightedText` (Equatable by revision), is computed on a detached task, and is applied via in-place `setAttributes`. Statistics are likewise computed off-main. This shape is also what M1.5's Neon integration needs. |
| 2026-06-12 | Keystrokes must not publish through the document model | Time Profiler showed per-key SwiftUI re-renders of the whole window (DynamicBody under `keyDown`) plus foreign-string traffic (`_StringGuts.foreign*`, CFStorage). `DocumentSession.text`/`version` are non-`@Published`; `isDirty` assignments are deduped; the coordinator eagerly `makeContiguousUTF8()`s the bridged string so downstream compares/counts run native. M2's preview must subscribe to text via its own debounced channel, not `objectWillChange`. |
| 2026-06-12 | Product named **Plainsong**; bundle id namespace `app.plainsong.*` | Owner decision. Verified no editor-category collision (App Store / GitHub; "plainsong" in software is liturgical-chant apps only). `plainsong.app` domain is registered by a third party — marketing site will need a variant; bundle id does not depend on it. Exported MDX UTI is `app.plainsong.mdx`; UserDefaults keys and JS bridge globals renamed in the same commit (saved window/preview prefs reset once). Repo folder name stays `blogeditor`. |
| 2026-06-12 | M2 scroll sync gets a narrow EditorKit scroll proxy exception | STTextView is an `NSView`, not `NSTextView`, so App-level hierarchy probing could never attach and retried forever. The exception is limited to `EditorScrollSupport.swift`, one optional `MarkdownEditorView(scrollProxy:)` parameter, and `MarkdownTextView` make/update wiring; `textViewDidChangeText` and the typing hot path remain unchanged. |
| 2026-06-13 | M4 editing behaviors get a narrow EditorKit command/interception exception | STTextView owns key input and undo, so editing behaviors must intercept `shouldChangeTextIn` and apply accepted transforms through STTextView insertion APIs. The exception is limited to `EditingBehaviorsSupport.swift`, one optional command-proxy parameter on `MarkdownEditorView`/`MarkdownTextView`, and a thin Coordinator delegate call; all transform logic stays pure in MarkdownCore, no textStorage writes are used for behavior edits, and the EditorKit boundary no-ops while IME marked text exists. Alt: App-layer text mutation was rejected because it would lose live selection and native one-step undo. |
| 2026-06-13 | M4 review fixes keep behavior edits pure and selection-aware | Ordinary non-trigger typing returns from EditorKit before whole-document materialization, menu commands share the Coordinator reentrancy guard, ordered task-list continuation increments and preserves checkbox markers, and Tab/Shift-Tab over selected list lines indents/outdents the selected block. Alt: deferring multi-line list indentation to M4 part 2 was rejected because the pure transform is small and covered by MarkdownCore tests. |
| 2026-06-13 | M4 reentrancy guard is a reference flag; `*` is wrap-selection-only | STTextView synchronously re-enters `shouldChangeText` during programmatic inserts, so EditorKit must never hold an `inout` or other mutating access to the editing-behavior guard across `insertText` or similar delegate-reentrant calls. The guard is a Coordinator-owned reference object read by reentrant calls. Maintainer decision: bare `*` inserts literally, selected text wraps as `*…*`, and `*` has no skip-over behavior; `_`, backticks, brackets, quotes, and MDX angle pairs keep existing auto-close behavior. Alt: keeping bold-first `*` auto-pairing was rejected because it blocks bullets and Typora-like italics. |
| 2026-06-12 | M3 keeps workspace ownership in WorkspaceKit and uses bookmark-backed Open Recent | File-tree reconciliation, directory scanning, FSEvents, file operations, bookmark recents, and LRU eviction stay below App so App composes rather than owns workspace rules. Preview assets resolve from the workspace root when a folder is open, while single-file mode keeps file-parent resolution. A simple File > Open Recent submenu backed by app-scope bookmarks was chosen over adopting NSDocumentController because Plainsong still owns custom folder workspaces and warm sessions. |
| 2026-06-14 | Preview stale-drop keyed on a controller `renderID`, not document `version` (bridge protocol v4) | The long-lived preview WebView dropped any render whose `version` was below the highest it had seen, but `DocumentSession.version` resets to 0 per file. After editing one file then selecting another freshly opened (lower-version) file, the new file's render was discarded and the preview stranded on the previous document. Fix decouples ordering from document version: `PreviewController` assigns a globally-monotonic `renderID` per render request used as the only drop key on both sides; `version` is retained solely for `checkboxToggled` writeback matching. Protocol bumped 3→4 with mirrored `BridgeMessage.swift`/`bridge.ts` and regenerated preview bundle. Alt: resetting the JS watermark on `fileURL` change was rejected because `baseDir` is not a reliable document identity (siblings share a directory) and it still needs a bridge signal. |
| 2026-06-15 | M4 review follow-ups route format commands by focused editor and preserve line endings | Format menu commands now dispatch through the AppKit responder chain to the key window's first-responder editor instead of a shared App-level proxy. MarkdownCore multi-line transforms operate on `MarkdownLine` content ranges and re-stitch original line terminators, and the code-fence helper only auto-inserts a closing fence for opening fences. Alt: per-window shared proxies were rejected because AppKit already owns the correct focused-editor routing. |
| 2026-06-15 | Defer independent multi-window document state | Phase 1 keeps one App-scoped `AppState` for `WindowGroup`, so multiple windows mirror the same current workspace/document even though Format commands route by first responder. Window-scoped `AppState` is deferred to a dedicated workspace/windowing change because it needs autosave, warm-session LRU, recents, and external-change behavior reviewed together. |
| 2026-06-15 | M4 completion uses a pure `CompletionWorkspace` value boundary | MarkdownCore owns ranking and context detection but receives only plain workspace-relative paths, heading anchors, learned frontmatter keys, and recency IDs. WorkspaceKit builds that value under security-scoped root access and enforces root containment; EditorKit asks STTextView's async completion delegate and applies selected replacements through STTextView insertion APIs. Alt: letting MarkdownCore read files or import WorkspaceKit was rejected by the layering rule; App-layer completion panels were rejected because STTextView already provides a native async completion window. |
| 2026-06-15 | MDX import parsing is shared in MarkdownCore | Component-name completion stays fresh by allowing the engine to rescan current text, while WorkspaceKit also precomputes names for the plain `CompletionWorkspace` value. A shared `MDXImportParser` in MarkdownCore removes duplicate import parsing without violating layering because WorkspaceKit already depends on MarkdownCore. Alt: relying only on WorkspaceKit was rejected because its debounced refresh can lag the current keystroke; keeping duplicate parsers was rejected as review-risky drift. |
| 2026-06-16 | Yams handles frontmatter YAML validation and typed loading | Frontmatter remains source-text-first: MarkdownCore uses Yams to validate and load the YAML mapping, then performs localized writeback so unknown keys, comments, body text, and line endings are preserved. Alt: hand-rolled YAML parsing was rejected because malformed YAML diagnostics and scalar/list semantics would be fragile; using Yams to dump whole mappings was rejected because it would reorder or normalize user-authored frontmatter. |
| 2026-06-17 | M5 TSX highlighting vendors tree-sitter-typescript TSX C sources | EditorKit now injects MDX ESM/JSX regions into a vendored `TreeSitterTSXFixed` target from `tree-sitter-typescript` v0.23.2 (`f975a621f4e7f532fe322e13c4f79495e0a7b2e7`) and maps TSX capture names into the existing MarkdownSyntaxToken/theme facade. Vendoring avoids the upstream Swift package's ChimeHQ/SwiftTreeSitter dependency, preserving the exact `tree-sitter/swift-tree-sitter` 0.10.0 pin and avoiding the Neon dependency-shape conflict. Alt: adding the upstream Swift package was rejected because it would reintroduce a conflicting SwiftTreeSitter graph; keeping `.mdxSource` coarse styling was rejected by §6.2/M5 acceptance. |
| 2026-06-17 | M5 MDX preview uses remark-mdx placeholders without bridge v5 | The preview pipeline adds `remark-mdx`, `mdast-util-mdx` node typing, and `rehype-sanitize` so `.mdx` files render Markdown normally while ESM, JSX components, and expressions become non-executed placeholders. MDX parse errors are handled entirely in preview JS with an inline banner and stale last-good content, so bridge protocol v4 remains sufficient. Alt: `@mdx-js/mdx` runtime compilation/component execution was rejected as Phase 3+ sandboxing work; native bridge diagnostics/protocol v5 are deferred until Swift-owned error chrome is required. |
| 2026-06-24 | M5 memory budget uses host-process RSS | The §12 memory gate is app host-process RSS with 8 warm sessions and 2 settled live preview webviews. PR #21 measured 149.8 MB host RSS and prints OS-managed WebKit helper memory as diagnostics only; helper reuse and process-pool ownership are too host-dependent to assert in CI. Alt: aggregating WebKit helper RSS was rejected for the M5 gate because the local diagnostic aggregate was 648.3 MB and not stable enough to compare across runners. Issue #13 is closed under this host-process RSS scope. |
| 2026-06-24 | PR #24/#27 M5 preview security rejects active HTML/SVG and uses bounded raster assets | Sanitized MDX/lowercase HTML strips inline `style` instead of CSS-sanitizing because Phase 1 has no user-authored CSS policy and style spoofing can cover the app with fixed or giant layout boxes. Script-like elements are dropped before sanitize so payload text does not leak into preview output. `asset://` preview serving and image file imports accept only PNG, JPEG, GIF, and WebP up to 10 MiB per file; inline user-authored SVG/path is rejected as active content until a dedicated sanitizer/design exists, and larger files should be inserted by link/reference outside the preview asset path. Alt: allowing all `UTType.image` files was rejected because it includes scriptable or memory-heavy formats. |
| 2026-06-24 | M5 settings use UserDefaults and opt-in HTTPS-only remote images | Settings persist through `UserDefaults` with the default folder stored as a security-scoped bookmark and no new persistence dependency. Editor settings apply by updating the existing STTextView font, gutter, and highlight theme instead of reloading document text; preview settings travel over bridge protocol v5. Remote images remain disabled by default; enabling them permits only `https:` image `src` values while keeping script, style, navigation, asset containment, and SVG rejection policies unchanged. Custom editor-theme JSON and user CSS overrides are deferred until separate import/sanitizer designs exist. Alt: broad WebView network allowance or arbitrary CSS/theme file loading in M5 was rejected as unnecessary release risk. |
| 2026-06-25 | M5 editor-to-preview scroll sync emits selection and visible-range source lines | The M5 checklist found that editor selection/Page Down movement could leave the preview near the previous top anchor even though source-line anchors existed. EditorKit now emits the source line containing the current selection and reported visible range through the existing scroll proxy, deduping repeated line sends and staying within the narrow M2 scroll-proxy exception. Alt: changing preview anchoring or adding a new bridge message was rejected because the failure was in when the existing editor line signal was emitted, not in the preview protocol. |
| 2026-06-26 | Phase 2 WYSIWYG design gate approves an inline-first v1 | Phase 2 v1 starts with source-range fold/reveal for headings, emphasis/strike, and inline code. Links are included only after the selection/copy spike keeps full `[text](url)` source ranges sane. Images, fenced-code custom fragments, tables, Mermaid, math, and real MDX rendering are deferred. Spike A/B/C (IME, undo, selection/copy) must pass before production implementation; WYSIWYG must not enter the user-facing ⌘⇧P cycle until a dedicated production PR proves the real mechanism. Alt: broad block rendering and attachment-heavy WYSIWYG were rejected until inline safety is proven. |
| 2026-06-26 | Phase 2 production fold/reveal core rides the visible highlighter parser and stays dev-only | Production fold/reveal is attached to `MarkdownHighlightService`/`MarkdownSyntaxParser` so syntax tokens and fold candidates share one visible block parse under the existing debounce, avoiding parser-per-keystroke and the initial 60.700 ms double-parse path. A default-off `_developmentPresentation: .inlineFoldReveal` hook exercises headings, emphasis/strike, inline code, and list/quote styling without changing App layout modes or the user-facing `⌘⇧P` cycle. Links remain in the range model but are not visually folded until native selection/copy edge semantics are specified. Alt: a standalone fold parser per update was rejected as a §12 performance regression; exposing WYSIWYG in layout prefs was rejected until actual IME streams and native selection gates pass. |
| 2026-06-26 | Phase 2 native gates use exact raw-copy policy and keep WYSIWYG blocked | For the attribute-only development hook, copy/paste/accessibility use the raw Markdown backing string: entire folded spans include delimiters, content-only selections copy content only, boundary selections copy exactly the selected `NSRange`, and paste mutates source text normally. Native arrow and shift-selection may enter delimiter offsets, but touched regions reveal on the next presentation pass rather than trapping the caret. Link visual folding remains deferred because link chrome and destination-edge selection need equivalent native coverage. Actual macOS Zhuyin/Pinyin event streams were not fully proven in this PR, so the App still must not expose or persist WYSIWYG. Alt: synthesizing rendered copy text or enabling link folding now was rejected as ambiguous source-range behavior. |
| 2026-06-26 | Actual Zhuyin IME commit keys stay owned by the input context while marked text is active | The opt-in actual TCIM Zhuyin event-stream harness found that candidate/commit keys can update marked text and still fall through to normal STTextView space/Return handling, corrupting source with whitespace/newlines. `MarkdownSTTextView` now reserves space, Return, and keypad Enter for `inputContext` while marked text exists. Pinyin remains blocked by local input-source enablement, so WYSIWYG stays non-user-facing. Alt: treating the newline as expected Return behavior was rejected because it couples composition commit to source mutation. |
| 2026-06-26 | Actual Pinyin IME event stream passes the inline fold/reveal gate; the actual-IME harness selects only composition-capable input methods | Enabling `com.apple.inputmethod.TCIM.Pinyin` with `TISEnableInputSource` made a real Pinyin IME selectable (direct selection had returned `-50` while it was disabled), and the opt-in harness drove physical `t/a/i → space` Pinyin composition (committing `太`) through the production `_developmentPresentation: .inlineFoldReveal` hook at heading, bold, italic, and inline-code fold boundaries with no source corruption, no caret escape from the marked range, no premature commit, fold attributes skipped during marked text, and presentation reapplied after commit. `ActualIMEInputSource.enabled(matching:)` now requires `kTISPropertyInputSourceType` to be a keyboard input method/mode so the gate never selects a same-named `TISTypeKeyboardLayout` (e.g. `com.apple.keylayout.PinyinKeyboard`) that produces no marked text; Zhuyin still selects its IME and stays green. IME is no longer a Phase 2 blocker, but user-facing WYSIWYG remains blocked pending native pointer hit-testing and a release checklist, and link visual folding stays deferred. Alt: selecting the first name-matched source was rejected because it can pick a non-composing keyboard layout and yield false IME evidence. |
| 2026-06-26 | Native pointer hit-testing passes with reveal-on-touch; delimiter edge-snapping is deferred to the user-facing WYSIWYG PR | `WYSIWYGNativePointerGateTests` dispatches real `NSEvent` left-mouse-downs at the laid-out screen position of folded heading/bold/strike/inline-code delimiters (target from `firstRect(forCharacterRange:)`, caret from STTextView's own `mouseDown → caretLocation` hit-test) and proves caret placement is sane, the touched span reveals on the next presentation pass, pointer-extend (shift-click) drag selection across folded spans copies exact raw Markdown with delimiters included, and no click traps the caret inside a hidden delimiter. Decision: for the attribute-only development hook, reveal-on-touch is sufficient and no delimiter edge-snapping is added at this layer, because any caret that touches a span reveals its delimiters before the next frame, so there is no trap and selection/copy stay on raw source offsets. Edge-snapping is a UX refinement owned by the user-facing PR. The current `baselineOffset(-1000)` zero-width fold mechanism lays a single folded line out ~1013 pt tall and distorts multi-line viewport (it does not trap the caret); a user-facing WYSIWYG must replace it with a cleaner zero-width mechanism (`NSTextLayoutFragment` customization or attachment hiding) and rerun the IME/selection/pointer gates against that mechanism. User-facing WYSIWYG stays out of `⌘⇧P` and persisted layout state; link folding stays deferred. Alt: adding edge-snapping to the dev hook now was rejected as redundant work that would complicate the raw-offset selection model the other gates depend on. |

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
