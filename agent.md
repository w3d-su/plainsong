# agent.md — Plainsong (Native macOS Markdown/MDX Editor)

> **Read this file fully before writing any code.** It is the single source of truth for
> architecture, conventions, and roadmap. If you (an LLM agent or human) make a decision
> that contradicts or extends this document, add a **Decision Log** entry (a new file in
> `docs/decisions/`, §18) in the same commit.

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

- iOS/iPadOS UI is outside the macOS roadmap. The separately authorized iOS/iPadOS 26+
  source-editor and preview work follows [`docs/ios/README.md`](docs/ios/README.md):
  12 parallel implementation lanes and one integration owner, frozen C0 interfaces,
  isolated worktrees, and M0 real-device gates before production composition.
  C0 supplies compile-time contracts and an unavailable app scaffold. Production
  providers, device validation, persistence, performance and IPA installation remain
  separate gates in `docs/ios/integration-ledger.md`.
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
| Text editor | [STTextView](https://github.com/krzyzanowskim/STTextView) (TextKit 2, AppKit) wrapped in `NSViewRepresentable` | Actively maintained; provides plugins and the completion window (line numbers are EditorKit's own, §6.1). Keep it behind our own `MarkdownEditorView` abstraction so it can be swapped for raw `NSTextView`+TextKit 2 if needed. |
| Syntax highlighting | [SwiftTreeSitter](https://github.com/tree-sitter/swift-tree-sitter) behind the EditorKit `MarkdownSyntaxHighlighter` façade | Async, visible-range highlighting; Neon adoption is deferred until its dependency graph is deterministic (§18). |
| Grammars | `tree-sitter-markdown` (block) + `tree-sitter-markdown-inline`, with injections: yaml (frontmatter), html, tsx (MDX/JSX regions), plus common fence languages (swift, js, ts, tsx, python, bash, json, css, html, yaml, go, rust) | Grammars vendored as SPM targets (each grammar repo ships an SPM package, or we wrap the C source). |
| Structure parsing (outline, etc.) | Reuse the tree-sitter syntax tree. Optionally [swift-markdown](https://github.com/swiftlang/swift-markdown) for export tasks. | Avoid two parsers driving the same UI. |
| Preview | `WKWebView` + local JS bundle built with **esbuild** from `preview-src/` | No remote network access by default (strict CSP). |
| Preview JS pipeline | unified: `remark-parse`, `remark-gfm`, `remark-frontmatter`, `remark-math`, `remark-mdx` (mdx only) → `rehype`, `rehype-katex`, `highlight.js` for fences; `mermaid` for ```mermaid fences; `morphdom` for incremental DOM patching | unified/remark is the standard 2026 pipeline and the only realistic path to MDX support. |
| Persistence of prefs | `UserDefaults` + built-in and imported editor color themes; user CSS deferred | |
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
│   ├── AppState.swift        # one façade per workspace window: WindowState + WorkspaceRootContext, sharing AppDocumentRegistry; KeyWindowRouter picks the key façade
│   ├── Views/                # SwiftUI views: WorkspaceWindow (split view), WorkspaceSidebar, WorkspaceDetail, DocumentJumpBar, WorkspaceInspector, WorkspaceToolbar, WorkspaceStatusBar
│   └── Resources/            # Assets, preview dist bundle (generated), themes
├── Packages/
│   ├── MarkdownCore/         # Pure logic: document model, markdown utilities, completion engine, scroll-sync mapping. No AppKit/SwiftUI imports. Testable via `swift test`.
│   ├── EditorKit/            # STTextView wrapper, tree-sitter highlighting, editing behaviors (AppKit)
│   ├── PreviewKit/           # WKWebView controller, JS bridge, asset URL scheme handler
│   └── WorkspaceKit/         # File tree model, FS watching, security-scoped bookmarks, atomic save
├── preview-src/              # JS/TS source for the preview pipeline (npm workspace)
│   ├── package.json
│   ├── src/index.ts          # bridge protocol impl, render(), morphdom patching, scroll sync
│   ├── src/pipeline.ts       # unified pipeline (md and mdx variants)
│   ├── src/styles/           # preview CSS (Apple system palette, Xcode-style syntax colors)
│   └── test/                 # vitest specs
└── .github/workflows/ci.yml  # parallel jobs: preview (Linux npm), packages (lint + swift test), hosted XCTest shards; `build-and-test` gate; docs-only PRs skip the test jobs (`changes`)
```

Build artifacts: `preview-src` builds to `App/Resources/preview/` (`index.html`, `bundle.js`,
`mermaid.js`, `bundle.css`, woff2 KaTeX `fonts/`). The dist output **is committed** so Swift-only agents can build the app without
Node installed; regenerate with `make preview-bundle` whenever `preview-src/` changes.

Manual Swift linker harnesses must include the approved portable package dependencies:
`WorkspaceKit` requires `WorkspaceCore`, while the parser extraction belongs to
`SyntaxKit`. Keep missing-object refusals and existing sandbox assertions. For iOS
package test admission, verify an enabled test plan, built test bundle and actual
named results; a library-only `build-for-testing` does not verify test compilation.
Current iOS runtime/provider/device gates are recorded in `docs/ios/integration-ledger.md`.


---

## 4. Architecture

```
┌────────────────────────── SwiftUI App Shell ──────────────────────────┐
│  WorkspaceWindow                                                      │
│  ┌──────────┐  ┌─────────────────────────┐  ┌──────────────────────┐  │
│  │ Sidebar  │  │  EditorPane (AppKit)    │  │  PreviewPane         │  │
│  │ FileTree │  │  STTextView + TreeSitter│  │  WKWebView + bridge  │  │
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
3. `MarkdownHighlightService` receives edits → tree-sitter re-parse → highlight attributes
   applied asynchronously to visible range.
4. A debounced (150 ms) subscriber sends `{text, version, fileKind, baseURL}` to the
   preview via the JS bridge. JS renders HTML, patches DOM with morphdom, reports back
   `renderComplete(version)`.
5. Scroll sync uses line ↔ DOM node mapping (§8).
6. Autosave: debounced 1 s after last edit + on window resign. `KeyWindowRouter` flushes
   the façade that resigned. The flush itself is app-global: it saves every connected
   window's document, warm session and retired session that may autosave. Writes use
   `Data.write(.atomic)`. The file watcher suppresses self-triggered events by comparing
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
- `WindowState` (App) — one window's document, layout, navigation, Find host, sidebar tree
  and search, completion metadata, prompts, errors, and export bookkeeping.
- `WorkspaceRootContext` (App) — one workspace root's scan snapshot, authority, generation,
  security scope, watcher, deferred refresh, and image-placement fence.
- `AppDocumentRegistry` (App) — per-file and app-global state that the cross-window
  invariants (`docs/window-state-gates.md` §3.4) must see: writers, bindings, external-change
  state, quarantine, session cache and LRU, recovery stores, notices, recents, preferences,
  services, and the one Replace authority generation. Its `sessions(from:)` enumerator over
  every connected window (`AppState.connect(_:)`), the warm cache, and the documented extras
  is the only session inventory, and only the registry touches the warm cache (§3.4 I2).
  `AppState` forwards the containers' remaining properties under the old names.
  `KeyWindowRouter` (App) maps each workspace window to its façade. Menus, Find, and the
  Carbon ⇧⌘F hot key ask it for the key façade when the command runs. A key sheet or
  child window resolves to its workspace window; any other key non-workspace window has
  no target, so commands do not fall back to a main window.

### Concurrency rules

- UI mutation on `@MainActor` only.
- tree-sitter parsing and highlight query execution off main thread (`MarkdownHighlightService`
  handles this; do not block it).
- Preview render requests are single-flight: one render is in JavaScript at a time and the
  newest request replaces the pending one, sent when the in-flight render posts
  `renderComplete` or after a 2 s watchdog (a throwing md pipeline or a stale-dropped render
  posts nothing). Stale `renderComplete` responses still free the slot but are otherwise
  ignored. A session render whose (session, version, file, presented document, asset root,
  theme, remote-image policy) equals the last submission is dropped as a duplicate.
- Editor highlight requests restart through `EditorHighlightScheduler`: each request cancels
  the executing request and replaces the pending revision in the caller's turn. One runner
  waits for cancelled work to return before starting the latest request, so at most one
  highlight parse executes, with bounded pending work. The 20 ms debounce starts before
  waiting for cancelled parsing. Do not drive them with SwiftUI `.task(id:)`, which was
  observed to drop the final request of a burst (Decision Log 2026-10-01).
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
- Descriptor-backed parent capture and document/image authority fall back to `O_SEARCH`
  when directory read access is denied. A single-file Powerbox grant permits parent lookup
  without directory enumeration; ordinary read descriptors retain permission-loss behavior.
- An explicitly selected iOS single-file Markdown/MDX document that is downloading or
  offline retains its current file grant and Files snapshot for Refresh and retry.
  Availability is reported separately from document type; actual revocation still fences access.
  Recent single-file restoration uses that same availability classification and retains
  a live pending selection for Refresh/retry. Cancelled, superseded, revoked or retired
  operations cannot keep an uninstalled scope; returned writers still drain safely.
- An iOS external reload rechecks its store's current proposal and lifecycle immediately
  before native installation, including proposals deferred before close. Closing holds
  the proposal without retiring its operation; failed close can resume it. Root watcher
  coalescing keeps root notices separate from byte-preserved child paths. The M0 prototype
  observes preopened replacement candidates and refuses changed candidates before attach.
  Explicit conflict reloads held by a retained close resume only for their current
  operation and authority; a later provider-loss event invalidates the proposal. M0
  rollback compares reopened bytes with the saved baseline before restoring editing,
  retaining local source under a conflict fence if the original changed while closed.
- Saves stage their temporary file beside the document and publish it with
  `renameatx_np`. A file-only grant (Open panel or Finder "Open With") refuses that sibling
  with `EPERM`; only then does the transaction stage in Foundation's item-replacement
  directory for the document (same device, never the parent itself), anchored by its own
  root authority and descriptor chain, and swap across directories with the same identity,
  expected-content, no-follow, durability and rollback checks. Folder-grant saves keep
  sibling staging. Any recovery artifact is reported at its staging-directory path;
  the emptied directory is removed. `Scripts/check-single-file-save-sandbox.sh` exercises
  this in a signed sandboxed probe under a LaunchServices file-only grant.
- Window chrome: a native `NavigationSplitView` with a resizable, collapsible sidebar
  (Files / Search navigators; ⇧⌘F in a window whose sidebar is hidden reveals it in
  Search) on macOS 27+, a fixed-width sidebar in an `HStack` before
  (R17), then the document column and a right inspector for frontmatter and file details.
  Inspector intent and width are per-window scene state; visibility is derived
  (`docs/window-state-gates.md` §10.1). The `HStack` shell's window minimum is 780 pt
  and the macOS 27 split shell's is 841 pt (320 pt sidebar, 0 pt measured chrome, and
  the 521 pt Split floor). The inspector auto-collapses when the document column cannot fit it.
- Open folder: sidebar shows the tree; filter to show only markdown-related files by
  default (`.md`, `.markdown`, `.mdx`), toggle "Show all files". Images shown so they can
  be drag-inserted. In the default mode the scan skips `WorkspaceIgnoredDirectories`
  (`node_modules`, `dist`, `build`, `.next`, `.astro`, `.build`, `deriveddata`, `.git`;
  the list Search ignores) without enumerating them; only the chain down to an open
  session's file in that root is scanned inside them. "Show all files" rescans everything.
- File tree operations: create/rename/delete/move file & folder (Finder-style, with
  trash not hard delete). Watch root recursively via `FSEventStream`; debounce 300 ms;
  reconcile tree diff instead of full reload to preserve expansion state.
  A reload whose final proof is superseded by document/session changes retries with a
  fresh capture in the same generation; a newer reload, workspace switch, or close cancels it.
- External change to the open file: if editor is clean → silently reload; if dirty →
  non-modal banner "File changed on disk: Reload / Keep mine".
- An active workspace search refreshes for document edits only after a 500 ms typing
  pause, and only while the Search navigator shows (an edit made while Files shows
  refreshes when Search shows again); typing never resets the search state.
- Each workspace window has its own `AppState` façade, `WindowState`, and
  `WorkspaceRootContext`, and they share one `AppDocumentRegistry`. One preview is
  created per visible document pane. A scene gets the app-owned façade whenever no open
  scene shows it, so closing the only window and reopening it works. A scene opened while
  another shows that façade refuses file and root opens and closes itself until PR D2, and
  native tabbing stays off until PR F. Same-file focus (WD1), shared-root
  release (WD2), and a user-facing New Window (D2) are not implemented yet.
- With no attached workspace window, New File, Open, and Open Recent wait for a scene
  that has claimed the owner. A three-second attach timeout lets the next command retry;
  a tracked façade alone does not establish that a scene exists.
- Tabs: native window tabs (`NSWindow.tabbingMode`) deferred; Phase 1 uses sidebar
  selection to switch the single editor pane (like Typora). Files selections defer out of
  the native List update, read and verify the file off the main actor, and commit only the
  latest still-current request against its installed workspace capture. Draggable filename
  labels also forward completed taps to that same deduplicated selection path, because
  native List selection alone misses those clicks on macOS 15. Publish the tree
  selection only after activation succeeds; a failed read keeps the current file selected
  and allows retrying the same row. Multiple open
  `DocumentSession`s kept warm in an LRU (target 8) so switching files is instant.
  A failed or fenced eviction candidate is retained and protected for the whole trim
  pass; each candidate is tried at most once per pass. The cache may exceed 8 while
  saves cannot complete, preserving unsaved content until a later trim can succeed.
  A session no App structure still owns (an untitled document, or a restored recovery copy
  after Stop Tracking) releases its unavailable ownership record on document switch or
  editor-binding removal, before its object identity can be reused.

---

## 6. Editor (EditorKit)

### 6.1 Base component

`STTextView` (AppKit, TextKit 2) hosted in `NSViewRepresentable` (`MarkdownEditorView`).
Configure: line numbers gutter (toggleable), invisible characters off, wraps lines,
variable-width font allowed (default: SF Mono 13 for source mode).

Line numbers are EditorKit's `EditorLineNumberGutterView`, which `EditorScrollView` tiles
left of the clip view; STTextView's `showsLineNumbers` gutter stays off (it rebuilt one view
per visible line and counted the paragraphs above the viewport on every layout pass). The
gutter only draws: the laid-out viewport fragments it shows, numbered from the shared
`EditorScrollLineIndex` (only `\n` starts a line), on the painted baseline of each source
line's first visual line (STTextView raises lines by half their line-height multiple's
extra height). Its width follows the line count's digits with hysteresis and never
changes while marked text is composed.

**Abstraction rule:** App/ and MarkdownCore/ must never import STTextView types. Only
EditorKit knows the concrete editor. This keeps the Phase-2 WYSIWYG swap and any library
replacement local to EditorKit.

### 6.2 Syntax highlighting

- `MarkdownHighlightService` runs tree-sitter parsing off the main actor and applies
  highlight attributes to the visible range; the façade keeps a later Neon swap local.
- Highlight requests include 1–4 Ki UTF-16 units of padding on either side. Viewport
  observations inside the pending/completed window reuse it without publishing a
  SwiftUI update. Edits, document/appearance changes and WYSIWYG selection changes
  still restart the revision-fenced scheduler; fence/frontmatter context is expanded
  once per source highlight, off the main actor.
- Fenced-code state has one definition, `MarkdownFenceScanner` (MarkdownCore), shared by
  the visible-range expansion, the Enter fence helper (§6.3) and MDX component
  completion (§6.5). CommonMark §4.5 per line (`\n`, `\r`, `\r\n`): a run of ≥ 3
  `` ` `` or `~` after ≤ 3 spaces (the Enter helper accepts any spaces/tabs, for
  list-item fences); a backtick opener's info string has no backtick; only the same
  character, at least as long, followed by nothing but spaces/tabs, closes; a leading
  `---`/`+++` frontmatter block closed by the same marker is skipped. It walks native
  UTF-8 storage with `memchr` (bridged strings as UTF-16) and returns UTF-16 offsets.
- Applying a highlight skips runs whose stored attributes already equal the new ones:
  re-setting equal attributes still marks the run edited, and TextKit then re-typesets
  every visible paragraph. The stored result is identical either way.
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
  cursor inside; language autocomplete fires after the opening fence. Inside an already
  open fence of either marker (`~~~` included, any indentation) nothing is inserted:
  the typed line is code or the closing fence.
- **Smart paste:** pasting a URL over selected text creates `[selection](url)`. Pasting an
  image from clipboard saves it to `assets/` (configurable, relative to the file) and
  inserts `![](path)`. Drag-in image files insert relative-path links (copy into
  `assets/` if outside the workspace).
- **Table helper:** Tab/Shift-Tab navigate cells; Enter adds a row; `Format Table`
  command (⌥⌘F) realigns pipes, preserving edge cells when outer pipes are omitted
  and treating escaped pipes as cell content. Pure formatting function lives in MarkdownCore.
- **Checkbox toggle:** ⌘L toggles `- [ ]`/`- [x]` on current line(s).

### 6.4 Formatting commands & shortcuts

| Command | Shortcut | Behavior (toggle, selection-aware) |
|---|---|---|
| Bold | ⌘B | `**…**` |
| Italic | ⌘I | `*…*` |
| Strikethrough | ⌃⌘X | `~~…~~` |
| Inline code | (Format menu; ⌘E is Use Selection for Find) | `` `…` `` |
| Use Selection for Find | ⌘E | set find pattern from selection; does not show bar |
| Find and Replace… | (Edit menu, no shortcut; ⌥⌘F is Format Table) | show the find bar, expand its replacement row, focus/select the query |
| Replace | (Edit menu, no shortcut) | replace the current match and advance; only while the bar is visible and the row expanded |
| Replace All | (Edit menu, no shortcut) | replace every match as one undo step; same eligibility as Replace |
| Link | ⌘K | `[sel](cursor)` |
| Insert Inline Math | (Format menu) | `$x$` with `x` selected, or wrap a single-line selection as `$sel$`; inside an existing formula selects its content instead; refused (beep, no edit) in frontmatter, code, or next to an unescaped `$` |
| Insert Display Math | (Format menu) | `$$` block padded to paragraph breaks; inside an existing formula selects its content; refused (beep, no edit) in frontmatter, code, or on list/quote/heading/table lines |
| Heading 1–6 | ⌘1…⌘6 | replace line prefix |
| Paragraph | ⌘0 | strip heading prefix |
| Quote | ⌘⇧Q | toggle `> ` |
| Code fence | ⌘⇧K | wrap selection in fences |
| Toggle preview pane | ⌘⇧P | show/hide right pane |
| Toggle sidebar | ⌃⌘S | native View › Show/Hide Sidebar (`SidebarCommands`; macOS 27+ split view only) |
| Toggle inspector | ⌃⌘I | View › Show/Hide Inspector (`InspectorToggleCommands`, key window) |
| Format table | ⌥⌘F | |
| Toggle checkbox | ⌘L | |
| New file | ⌘N | workspace: dedup `Untitled.md` at root; single-file: save panel |
| Print… | ⌘P | File menu: print the captured light-theme PDF through the standard panel |

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

Workspace paths and sibling frontmatter keys are read once per installed workspace capture
and current file (keys from the first 32 KiB of up to 50 siblings, no digest); a typing
pause recomputes only heading anchors and MDX component names, and `completionWorkspace`
republishes only when its value changes literally.

---

## 7. Preview (PreviewKit + preview-src)

### 7.1 Web view setup

- One `WKWebView` per editor pane, non-opaque, loads the bundled `index.html` once and
  stays alive (re-render via JS, never reload the page per keystroke). Only the editor
  view's `@StateObject` state owns its `PreviewController`: closures stored on the
  controller or handed to AppKit views capture the objects they use, never the view
  struct, so closing the workspace root releases the controller and its web view.
  The controller (and so its WebContent process) is created the first time the preview
  pane is shown (`LazyPreviewController`); a source-only window has none. Hiding the pane
  keeps it. After a WebContent termination a live controller reloads the page and
  re-submits its newest render under a new render ID, giving up after three terminations
  without a completed render (each later render retries once); export controllers fail.
  Only iOS arms the one-shot 2.5 s silent-initial-page retry; macOS retains its normal
  initial load. A retry with no navigation token probes the current page when ready
  arrives, and accepts only a protocol match from the current page generation.
- **Security:** strict CSP (`default-src 'none'; script-src 'self'; style-src 'self'
  'unsafe-inline'; img-src asset: data: https:`), `isElementFullscreenEnabled` off, and
  no remote loads by default. The preview JS removes remote image `src` values unless
  the user enables the Allow Remote Images preference; that preference permits only
  `https:` images and does not relax script, style, navigation, or non-image network
  behavior.
- **Local assets:** custom scheme `asset://` via `WKURLSchemeHandler`. JS rewrites
  relative image/link `src` to `asset://<workspace-relative-path>`; the handler resolves
  against the current file's directory / workspace root. Render payloads carry an opaque
  `assetRootID`; local image URLs include it as a query token so a root change invalidates
  retained image loads, and delayed requests with an obsolete token are rejected. The handler enforces path containment
  (reject `..` and symlink escapes outside the workspace). It serves PNG, JPEG, GIF, or
  WebP up to 10 MiB, and UTF-8 `.svg` up to 1 MiB when `SVGImageValidator` admits it:
  no DOCTYPE or non-UTF-8 declared encoding, no script, foreign content, event handlers,
  or external references (CSS is scanned after decoding escapes, SMIL values included),
  at most 50,000 elements and depth 256. An admitted SVG is served byte-for-byte as
  `image/svg+xml; charset=utf-8` with `X-Content-Type-Options: nosniff` and response
  `Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'` (a
  document-mode backstop; image mode is the barrier). Without those headers the request
  fails. Validation runs off the main actor; the reader's file and the requested file
  must agree on being SVG, and the Mac reader reads only a regular file, bounded. `data:image/svg+xml` and inline
  `<svg>` stay blocked. HTML and PDF export do not embed SVG yet. Other active or
  ambiguous formats are rejected.
- Link clicks: intercepted in Swift. `http(s)` → `NSWorkspace.open` (external browser).
  Relative `.md`/`.mdx` → open that file in the editor. `#anchor` stays in JavaScript
  and scrolls the preview to a generated heading ID (Unicode and duplicate headings supported).
  On iOS, PreviewKit also owns external browser opening; production scene observation
  must not open its informational external-link event a second time.

### 7.2 JS pipeline (preview-src)

Two unified pipelines selected by `fileKind`:

- `md`: `remark-parse` → `remark-gfm` → `remark-frontmatter` → `remark-math` →
  `remark-rehype` → `rehype-katex` → custom rehype plugin `rehype-source-lines` (adds
  `data-line` from AST `position` to block elements) → `rehype-stringify`.
- `mdx`: same + `remark-mdx`; a custom remark plugin transforms `mdxJsxFlowElement` /
  `mdxJsxTextElement` / `mdxjsEsm` nodes into placeholder HTML (§9) instead of compiling.

Both run through `SegmentedRenderer`. It cuts the text at verified block boundaries and
re-renders only changed segments, returning the exact whole-render string. A cut inside an
open construct retries past where it closes. Definitions, footnotes and documents that do
not parse render whole, with no segment pass while that holds; ESM after an import merges
segments (`docs/decisions/2026-10-24-preview-segmented-render.md`).

Post-render in browser: `highlight.js` handles non-Mermaid code fences. A fence with no
info string auto-detects its language only up to 4,000 UTF-16 units
(`AUTO_DETECT_MAX_LENGTH`); a longer bare fence renders as plain text, because
auto-detection cost grows superlinearly with line length. Before the live
DOM patch, Mermaid fences become `div.mermaid-rendered` placeholders carrying the exact
fence source, its Mermaid-fence ordinal, and the current Mermaid-theme generation.
`morphdom` keeps a matching successful live wrapper. A changed wrapper receives the new
descriptor and `.mermaid-pending` state while retaining its previous SVG children only
as a stale visual until rendering settles; pending wrappers are never authoritative,
and success or `.mermaid-error` replaces those children. Remaining placeholders use a
64-entry success-only LRU keyed by the exact JavaScript source string + ordinal tuple,
and misses call `mermaid.render` (the first miss loads `mermaid.js`, §7.4; a failed load is
an ordinary `.mermaid-error` and the next render retries). Exact-string comparison, not the removed 32-bit djb2
hash, authorizes reuse. The ordinal is part of the key because Mermaid output embeds its
render ID in SVG IDs and references; reusing one SVG string for identical fences at two
positions would duplicate IDs. Inserting or removing a fence therefore deliberately
invalidates every shifted following ordinal. Concurrent identical misses coalesce in a
separate in-flight table with the same 64-entry bound. Failed renders remain
`.mermaid-error`, are not cached, and retry on the next render. A preview-theme change
reinitializes Mermaid, clears both tables, and re-renders every visible diagram because
the theme is baked into its SVG. Checkbox inputs remain enabled and clickable.

DOM update: render to HTML string → prepare Mermaid placeholders → `morphdom` patch
against live DOM (retaining a changed diagram's prior SVG while pending) → resolve
pending Mermaid wrappers. This preserves unchanged Mermaid SVG DOM, unchanged
highlighted-code DOM, scroll position, and image loads.

Frontmatter is **not** rendered as a table in the preview body; it is stripped (shown in
the Frontmatter panel, §10). Optional toggle to show it as a styled block. A leading `---`
with no closing fence is not frontmatter in the preview: `remark-frontmatter` runs only
when the block closes (`src/frontmatter.ts`), because its concrete construct otherwise
stops lists and block quotes from opening anywhere in the document. The `---` renders as
a thematic break; the inspector still reports the missing closing delimiter (§10).

### 7.3 Swift ↔ JS bridge protocol

`window.webkit.messageHandlers.bridge.postMessage(...)` (JS→Swift, read field by field from
the Foundation body, never through `JSONSerialization`) and
`window.PlainsongBridge.receive(message)` (Swift→JS). `render` goes through
`callAsyncJavaScript` with the message as a Foundation argument, so the document text is
never JSON-encoded, interpolated into a script, or parsed as source; the other messages are
JSON-encoded into an `evaluateJavaScript` script. Both carry the same message shape. Keep the protocol in
`BridgeMessage.swift` + `ExportBridgeMessages.swift` (Codable) and `bridge.ts` —
**these must be kept in sync; both sides list message names in the same order with a
`PROTOCOL_VERSION` constant checked at `ready`.**

| Direction | Message | Payload |
|---|---|---|
| JS→Swift | `ready` | `{protocolVersion}` |
| Swift→JS | `render` | `{renderID, version, fileKind, text, baseDir, assetRootID, theme, allowRemoteImages}`; `renderID` is a controller-assigned globally-monotonic stale-drop key (ordered across document switches); `version` is the per-document `DocumentSession.version` used only for `checkboxToggled` round-tripping; `baseDir` is the workspace-root-relative parent directory for the rendered file, or `null` for single-file/root renders |
| JS→Swift | `renderComplete` | `{renderID, version, blockCount}` |
| Swift→JS | `scrollToLine` | `{line, animated}` |
| JS→Swift | `previewScrolled` | `{topVisibleLine}` (only while preview owns scroll) |
| JS→Swift | `linkClicked` | `{href}` |
| JS→Swift | `checkboxToggled` | `{renderID, line, checked, version}` → Swift requires the latest submitted render ID and version, its retained originating `DocumentSession` instance, and the current document/version to match (protocol v7). Retained error DOM keeps its original render ID. |
| Swift→JS | `setTheme` | `{theme}` |
| Swift→JS | `exportHTML` | `{exportID, renderID, phase, documentTitle, resourceOutcomes}`; `phase` is `discovery` or `finalization`. PreviewKit—not JS—supplies typed embed/omit outcomes in the finalization round; a repeated accepted image names its first outcome through `dataURIFrom` instead of repeating the data URI (protocol v8). |
| JS→Swift | `exportHTMLResult` | `{exportID, renderID, state}` where `state.kind` is `resourcesNeeded`, `ready(html)`, or `failed`. `ready` is the shared export-ready barrier and is illegal for MDX stale/error DOM, before finalization, or before fonts/images settle. |

### 7.4 Build

`make preview-bundle`: `npm ci && node build.mjs` → `App/Resources/preview/`. esbuild emits two
classic IIFE scripts: `bundle.js` (everything parsed at start-up, kept under 1 MB by
`test/bundle-budget.test.ts`) and `mermaid.js`, which `src/mermaid-loader.ts` injects on the
first diagram so documents without diagrams never parse Mermaid. Do not switch to ES module
splitting: the page is a file: URL, where module scripts hit CORS. Only the woff2 KaTeX fonts
ship, and the build strips the woff/ttf fallbacks from KaTeX's CSS. Syntax highlighting uses the preview
stylesheet’s Apple system palette and Xcode-inspired light/dark token colors, with dark
function/link/comment colors raised to meet 4.5:1 on code background `#2a2a2c`.
The highlight.js `github.css` theme is no longer bundled. All assets are bundled
locally. No CDN, app must work fully offline. Commit the dist output.

---

## 8. Scroll Sync

Mapping basis: `data-line` attributes emitted by `rehype-source-lines` on every
block-level element.

- **Editor → preview (primary direction):** on editor scroll, compute first visible
  source line (the layout fragment at the visible top edge, not the TextKit viewport
  start, which STTextView extends above the visible area) → `scrollToLine`. JS finds the
  nearest `[data-line]` ≤ line and the next one > line, interpolates between their
  document-relative tops proportionally to line distance → smooth, accurate positioning.
- The preview keeps a line-sorted `[data-line]` anchor list, rebuilt only after DOM
  mutations (`MutationObserver`, with `takeRecords()` for same-turn changes), and
  binary-searches it. `scrollToLine` reads live layout tops for the two bracketing
  anchors only, so resize, image, font or Mermaid reflow can never leave it stale and
  no resize frame re-measures the document. Tops are layout coordinates: `offsetTop`
  summed over offset parents (tables, positioned MDX blocks); unrendered anchors
  (`display: none`, closed `<details>`) are skipped.
- **Preview → editor:** symmetric, using `previewScrolled`. The top-ordered anchor
  list is measured lazily and reused while the two anchors bounding a lookup are still
  where it recorded them; otherwise it is re-measured.
- **Reflow:** the preview remembers the (fractional) source position at its top and
  its actual pixel offset from the mapped anchor. A width change (`ResizeObserver`,
  before paint) adjusts scrolling only when that anchor's layout top changes and
  the browser has not already placed it at the target. Width notifications without
  anchor reflow leave scroll position and ownership untouched. The pixel offset
  survives repeated resizes without accumulating scroll-coordinate rounding.
- The editor's source-line index is edited in place from `willChangeTextIn`
  (O(log n) per keystroke; a full rebuild walked the 1 MiB storage on every selection
  change), with a length check and a change-notification fallback that rebuild in bulk.
- **Loop prevention:** a `scrollOwner` token (`editor` | `preview` | `none`) with 100 ms
  decay (a deadline timestamp, not a timer per event); messages from the non-owner are
  dropped.
- Editor viewport traffic carries no completion: one `scrollToLine` is in flight and only
  the newest line waits. Document navigation keeps its render barrier and receipt, and
  discards waiting viewport lines so they cannot scroll back over it.
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
    stripped or dropped. Sanitization precedes trusted KaTeX generation so generated
    math layout styles survive without allowing user-authored styles.
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
- Inspector form (right column, ⌃⌘I, Frontmatter section): key/value editing with
  type-aware controls (string, date picker for `date`, tag token field for `tags`, toggle
  for `draft`).
- Edits write back into the source text (panel ↔ text always derived from the document;
  the text is the single source of truth). An inspector edit is computed from the session's
  text at that moment and shown at once; editor typing reaches the panel after a 150 ms
  pause, and the Yams parse reruns only when the frontmatter block itself changed.
- Malformed YAML → panel shows raw text + error, never crashes, never rewrites what it
  cannot parse.
- String and string-list form writes use explicitly quoted YAML scalars with serializer-owned
  escaping, preserving literal contents and string types through parse/writeback.

---

## 11. Theming & Settings

- **Editor themes:** two built-ins (`standard`, `graphite`) plus imported color themes.
  Settings › Editor imports a JSON file (`NSOpenPanel`) and copies the validated bytes
  into the sandbox container at `Application Support/Plainsong/Themes/<id>.json`. No
  bookmark is kept. Re-importing an id asks before replacing that copy. Reveal in Finder
  and Remove act on the copy; Remove moves it to the Trash. Schema v1 is colors only
  (`#RRGGBB` or `#RRGGBBAA`, 64 KiB, closed keys): an unknown field rejects the whole
  file, and a missing slot inherits the built-in. An unreadable selected theme falls
  back to Plainsong for that launch with a non-modal notice and keeps the stored id.
  Switching themes recolors the open editor without reloading the document. Fonts, user
  CSS, and Mermaid colors from tokens stay deferred. The design is
  `docs/custom-themes-design.md`; preview tokens in the same file are validated and
  stored but not applied until the `setThemeTokens` bridge.
- **Preview themes:** bundled CSS variables for system/light/dark preview themes, paired
  with the editor settings bridge. User CSS overrides are deferred until a separate
  sanitizer/design exists.
- **Settings window (SwiftUI `Settings` scene):** General (default folder, autosave
  interval), Editor (font, size, theme import, line numbers, typewriter sync), Preview
  (theme, allow remote images), Files (image-paste asset folder pattern, default
  extension `.md`/`.mdx`).

---

## 12. Performance Requirements

| Metric | Budget |
|---|---|
| Keystroke → screen (typing latency) | < 16 ms (never block main thread on parse) |
| Highlight update after edit | < 50 ms visible range, async |
| Preview update (debounced) | render < 100 ms for 100 KB doc; debounce 150 ms |
| File open (500 KB md) | < 300 ms to first paint, highlight may stream in |
| Memory (app host RSS) | < 400 MB in the Plainsong host process with 8 warm sessions + 2 settled live WKWebViews |

Techniques: tree-sitter incremental edits (`InputEdit`), visible-range-first
highlighting, a line-number gutter that draws only the visible viewport fragments from an
incrementally edited line index, segment-cached preview renders, morphdom patching,
render-version dropping, LRU sessions,
and bounded success-only Mermaid memoization by exact fence source + Mermaid-fence ordinal
within a theme generation. The ordinal prevents duplicate Mermaid-generated SVG IDs when equal
source appears more than once; inserting or removing a fence intentionally invalidates
shifted following ordinals. While a changed diagram renders, morphdom keeps its prior
SVG children only as non-authoritative pending content, avoiding a temporary collapse.
**Any PR that regresses typing latency is rejected regardless of features.** Add a
`PerformanceTests` target with a large fixture (`Fixtures/large-1mb.md`).

Editor main-thread rules (profiled 2026-10-18; evidence in `docs/perf-log.md`): no
O(document) work per keystroke on the main thread. Publish native UTF-8 source strings,
never the bridged `NSTextStorage` string: SwiftUI compares published text with `==`,
which normalizes a bridged string from its first character. Edit derived indexes in
place. Release TextKit 2's cached text elements below the viewport once scrolling
settles (`EditorTextElementCacheTrimmer`): each edit rewrites the range of every cached
element after it, so typing above a once-viewed document end cost ~50 ms per keystroke.
Admit each chunk against the real live viewport and selected paragraphs immediately
before its attribute edit; a captured range is only a candidate. Keep their prefetch
protection while releasing safe ranges around an offscreen selection. Selection-only
changes reschedule trimming without republishing an unchanged viewport.
The synchronous typing gates do not see SwiftUI, layout or display work a keystroke
schedules; typing with the preview visible is measured by the opt-in hosted
busy-slice probe (`MainThreadStallHostedTests`, `TEST_RUNNER_PLAINSONG_RUN_SCROLL_PROBE=1`).

M5 planning note: the highlight budget is accepted only from visible-range-first
highlighting instrumentation, not from the historical 250 KB full-document inline
parsing cutoff. The memory budget is scoped to deterministic app host-process RSS.
OS-managed WebKit helper processes should be recorded as diagnostic/informational
data because helper reuse and process-pool ownership vary across runs and CI hosts.

Record a new measurement as `docs/perf/YYYY-MM-DD-<slug>.md`, one file per entry.
`docs/perf-log.md` is the archive and takes no new sections; its header has the file
format. The 2026-10-18 profile above, and every earlier budget, stay in that archive.
`Scripts/editor_find_f2_evidence_tests` still reads the F2 trust-root rows there.

---

## 13. Phase 2 — Typora-Style WYSIWYG (Experimental; gates in `docs/wysiwyg-release-checklist.md`)

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
- Experimental single Replace edits raw UTF-16 source only. When the current match is
  not the selection, the action only selects it and synchronously removes any image
  marker over it; folded owners reveal later through the existing debounced
  selection-driven reparse. An action whose selection already is the match (even the
  first, e.g. after Find selected it) commits only if the last applied presentation at
  the current revision shows each overlapping owner revealed, no folded attribute over
  the match or those owners' own delimiter/link chrome, and no image marker over the
  match or an overlapping image; untouched nested constructs may stay folded. Otherwise
  it refuses with zero effect (`wysiwygRangeNotRevealed`). Normal off-main reparse
  restores presentation after the write and native Undo/Redo. Replace All prepares
  a minimal raw enclosing slice off-main, suspends folds/image presentation once,
  and commits in one synchronous authorized native insertion. Failed batch writes
  reset presentation caches and request one fresh derivation; real-IME and full
  performance acceptance remain open.
- The two-pane mode remains available behind a toggle forever (⌘⇧P cycles: source+preview
  / source only / WYSIWYG once it ships; the toolbar layout picker selects a mode directly).

---

## 14. Roadmap & Milestones (Phase 1)

Phase 1 milestones were delivered in order and are all accepted; each lists the criteria it passed.

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
component rendering. The independent iOS lane follows `docs/ios/contracts.md`: iOS 26+,
source plus preview, Files/iCloud in-place access, native UIKit editor and UIDocument
persistence. The first C0 PR owns declarations/scaffolds only; 02/03 perform shared
core extraction, 13 retains contracts/composition, and 12 receives global build
manifests after the recorded C0 transfer. iOS-only packages stay out of Mac `make test`.

The iOS acceptance review uses a separate aggregate of the published lane heads;
fix commits preserve the frozen declarations and unavailable C0 composition. Shared
package dependency inventory tests pin SyntaxKit's two existing parser dependencies
and WorkspaceKit's WorkspaceCore path after extraction. A successful test action must
report executed named cases; skip, empty results, lock admission timeout, and simulator
installation failure remain distinct. Real PreviewKit tests load byte-verified resources
inside the test container with the original CSP, bounded JavaScript replies, and cleanup
registered before the first await. M0 device and re-signed IPA installation gates stay
open until owner evidence is recorded. The current review receipt and next-agent
handoff live in `docs/ios/evidence/review-20261013/README.md`; an aggregate compilation
and a portable Mac logic run do not close native or owner acceptance.

Lane 12 owns the separate `IOSPreview` / `make ios-preview` entry. Its dedicated
SwiftUI app host links system frameworks only; PreviewKit and MarkdownCore are
linked in the unit-test bundle, avoiding duplicate package classes in the host.
Admission must prove a built app-hosted Mach-O unit-test bundle. The full suite
retains all original 94 cases and rejects skips; a separate first-controller run
loads the production-default app-bundled index after byte parity checks. Keep the
8-second ready and 2-second JavaScript limits. `PreviewKit-Package` remains the
hostless package diagnostic, not the iOS app-host acceptance entry. This test
scaffold does not install providers or authorize production composition before M0.

---

## 15. Build, Run, Tooling

```sh
make bootstrap        # brew install xcodegen swiftformat swiftlint node; npm ci (preview-src)
make generate         # xcodegen generate  (run after editing project.yml)
make preview-bundle   # build preview-src → App/Resources/preview/ (commit the output)
make build            # xcodebuild -scheme Plainsong build
make test             # test-packages (swift test) + test-hosted (xcodebuild test) + test-preview (npm test)
make test-hosted XCODE_TEST_TARGETS=PlainsongTests  # one hosted bundle subset, as a CI shard runs it
make release          # DMG pipeline (Scripts/release.sh); PLAINSONG_UNSIGNED=1 for the alpha path
cd preview-src && npm run typecheck  # preview TypeScript check; CI runs this separately
make format           # swiftformat . && swiftlint --fix
```

- CI installs **SwiftFormat 0.62.1** as a SHA-256-verified release binary
  (`.github/workflows/ci.yml`, mirrored by `SWIFTFORMAT_VERSION` in the Makefile), not via
  Homebrew, so lint results cannot drift with the runner image. Local `make lint` warns when
  the Homebrew version differs; CI is authoritative. Bumping the pin means updating the
  version + SHA-256 in `ci.yml`, the Makefile constant, and reformatting the tree in the
  same PR if rule behavior changed.
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
2. **Scope:** one gate or goal per PR; don't start the next gate's work inside the current one.
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
   state how you verified typing latency. Record the measurement as a new file,
   `docs/perf/YYYY-MM-DD-<slug>.md` (format in the `docs/perf-log.md` header). Do not
   append a section to `docs/perf-log.md`: that shared end made open performance PRs
   conflict, and resolving the conflict forced a full CI run.
9. **Main-thread discipline:** parsing/rendering off main; UI on `@MainActor`. No new
   `DispatchQueue.global` calls.
10. **Naming/style:** Swift API Design Guidelines; SwiftFormat config is authoritative;
    no abbreviations in type names; files ≤ ~400 lines, split by extension/feature.
11. **Commits:** imperative subject, body explains *why*; reference milestone (e.g.
    `Phase 3: add scroll owner arbitration`).
12. **When uncertain about UX,** match Typora's behavior first, macOS HIG second, then ask.
13. **Update documentation:** behavior changes → update relevant § here; architectural
    choices → a new file in `docs/decisions/` (date, decision, why, alternatives; §18).
14. **Branch + PR workflow:** `main` is protected. Do all work on a branch named
    `phase<N>-<slug>` (e.g. `phase3-editor-find-bar-ui`) and open a PR against `main`.
    State the branch name when you start. Never push to `main` directly, never force-push,
    and never merge your own PR —
    the maintainer merges (squash) after review and green CI. One milestone (or one
    review-fix batch) per PR.

---

## 18. Decision Log

Add each decision as its own file, `docs/decisions/YYYY-MM-DD-<slug>.md` (decision, why,
alternatives considered), in the same commit as the change. The format and the archive
table of earlier decisions are in [`docs/decision-log.md`](docs/decision-log.md); never
append rows to that table, because a shared last line made every pair of open PRs
conflict. Current rules in §1-§17 are authoritative. Read the log when you need the
rationale behind a rule or are about to revisit a past decision.

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
