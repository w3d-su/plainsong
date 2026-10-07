# Native macOS UI plan

Goal: Plainsong should look and behave like an app Apple ships on macOS 26/27: system
materials, stock controls, SF Symbols, semantic colors, and the HIG's placement rules. We
get Liquid Glass mostly by using standard containers and controls (`NavigationSplitView`,
toolbars, segmented pickers, menus, grouped forms). The few custom floating
surfaces (notice cards, sidebar bottom buttons) use `plainsongGlass`, which wraps
`glassEffect` and falls back to a system material. The deployment target stays macOS 14,
so any macOS 26-only API needs an `if #available` fallback.

Reference apps: Xcode 27 (navigator selector, jump bar, inspector) and Notes (full-height
glass sidebar, minimal glass toolbar).

## Rules

- Prefer the stock control over custom chrome. If SwiftUI/AppKit has the control (`List`
  selection, `ContentUnavailableView`, `Form` with `.grouped` style, `Menu`), use it.
- Colors come from semantic styles (`.primary`, `.secondary`, `.tint`, `.bar`,
  `.quaternary`) or the Apple system palette. No hard-coded GitHub-style hex values in
  chrome.
- Inline notices use `NoticeBar`, a floating glass card: message leading, actions
  trailing, primary action last.
- No SwiftUI focused values (`focusedSceneValue`, `focusedSceneObject`) on the workspace
  window; they delayed the editor's own updates in the hosted gates. Window-scoped menu
  commands go through a key-window registry such as `InspectorMenuState`.
- No SwiftUI `.inspector` in the workspace window. With it mounted (on the detail column
  or the split view, even with static content), the editor's SwiftUI updates intermittently
  stalled in the hosted Find/Replace gates, so Find navigation and WYSIWYG reveal never
  applied. The inspector is `InspectorColumn` inside the document column, with plain
  sections (`InspectorSection` / `InspectorRow`) as in Xcode. A grouped `Form` there made
  the stall deterministic; Settings, a separate window, keeps its grouped forms.
- Presentation-only changes must not move focus, responder, or accessibility identities.
  Workspace Search keeps its owned `NSTextField`, key routing, and the F6/F7 gates.
- R17: the main window is a `NavigationSplitView` again. Its detail content must stay
  inside the `GeometryReader` in `WorkspaceWindow`, or the split column's min-size updates
  loop until AppKit throws (`docs/risk-register.md` R17).

## Landed (phase3-native-macos-polish)

| Surface | Change |
|---|---|
| Window shell (PR L) | `NavigationSplitView`: full-height floating glass sidebar on macOS 26+, user-resizable (220–320 pt) and collapsible (⌃⌘S). Per-window scene state; layout recorded in `docs/window-state-gates.md` §10.1. |
| Toolbar | Liquid Glass: title = document name, subtitle = workspace folder; a Source / Split / WYSIWYG segmented picker (⌘⇧P still cycles) and an inspector toggle. Open and Save stay in the File menu and the empty state. |
| Navigator selector | Xcode-style navigator bar replaces the segmented picker: a small Liquid Glass capsule of outlined icons (Files, Search), the selected one full-strength on a sliding highlight. Same accessibility identifier and Search unmount behavior. |
| Jump bar | Replaces `DocumentHeader`: workspace › folders › document, file kind badge, saving spinner. As in Xcode, a folder segment lists its contents (subfolders as submenus) and the document segment lists its siblings; choosing a file opens it like a sidebar click. Right-click copies the name, path, or workspace-relative path, or shows it in Finder. Keeps the `plainsong.editor.fileName` identity. |
| Inspector | Right column (⌃⌘I), Xcode-style plain sections (bold header, trailing-aligned labels, small controls): Frontmatter (switches, date pickers, wrapping tag chips, invalid-YAML warning with selectable raw YAML) and File (name, type, location, Show in Finder). Replaces the sidebar Frontmatter section. |
| Files sidebar | Native source list: `List(selection:)` highlight (including inactive-window gray), the workspace root as an Xcode-style bold top row, `ContentUnavailableView` when nothing is open, and floating glass Add (+) and Filter buttons. The context menu adds New File/New Folder and Show in Finder. |
| Empty state | `ContentUnavailableView` with **Open…** and up to five recent items. |
| Status bar | Line, word, and character counts in caption type with monospaced digits. |
| Settings | System Settings idiom: grouped forms, sections, explanatory footers, and value-then-stepper rows. |
| Banners | Every editor notice (missing file, uncertain save, workspace recovery, external change, WYSIWYG fallback) is a `NoticeBar` glass card. |
| Workspace Search | Appearance only: filled search-field capsule, compact option toggles, Xcode Find-navigator style file headers (name, dimmed folder, count badge). |
| Preview CSS | Apple system palette. Dark background is `#1e1e1e` so it matches the editor. Xcode Default (Light/Dark) syntax colors replace highlight.js `github.css`, which painted a white nested box inside every code block in dark mode. |

## Deferred until in-flight PRs merge

These were left untouched on purpose, to avoid conflicts. Fold each into the named PR or
do it right after it merges.

### Main window: per-window state after #139 C

The chrome landed as PR L. C replaces the views' shared `AppState` with each window's
state; no further layout move is planned. Still open: a Pages-style word-count popover on
the status bar, if wanted.

### Find / Replace bar and Edit menu: after #151

Restyle the bar to read like Safari's or Xcode's: bar material, a search field with the
match count inside it, a previous/next segmented control, and a trailing **Done**. Keep
#151's focus, IME, and responder contracts as they are.

### File menu and export banner: after #147 and its follow-up (20a)

Show export progress and outcome with `NoticeBar` (or the window's toolbar progress)
instead of a bespoke banner. Menu titles follow the HIG ellipsis rule ("Export as PDF…",
"Print…").
