# Native macOS UI plan

Goal: Plainsong should look and behave like an app Apple ships on macOS 26/27: system
materials, stock controls, SF Symbols, semantic colors, and the HIG's placement rules. We
get Liquid Glass by using standard controls (segmented pickers, toolbars, menus, sidebars,
grouped forms), never by imitating it with custom shapes. The deployment target stays
macOS 14, so any macOS 26-only API needs an `if #available` fallback.

## Rules

- Prefer the stock control over custom chrome. If SwiftUI/AppKit has the control (`List`
  selection, `ContentUnavailableView`, `Form` with `.grouped` style, `Menu`), use it.
- Colors come from semantic styles (`.primary`, `.secondary`, `.tint`, `.bar`,
  `.quaternary`) or the Apple system palette. No hard-coded GitHub-style hex values in
  chrome.
- Inline notices use `NoticeBar`: message leading, actions trailing, primary action last.
- Presentation-only changes must not move focus, responder, or accessibility identities.
  Workspace Search keeps its owned `NSTextField`, key routing, and the F6/F7 gates.
- R17 still holds: the sidebar stays inside the fixed-width `HStack`. It draws the system
  sidebar material (`SidebarMaterialBackground`) instead of becoming a split view.

## Landed (phase3-native-macos-polish)

| Surface | Change |
|---|---|
| Sidebar shell | System sidebar material. The mode picker no longer has a hard divider under it. |
| Files sidebar | Native source list: `List(selection:)` highlight (including inactive-window gray), collapsible workspace and Frontmatter sections, `ContentUnavailableView` when nothing is open, and a bottom bar with Add (+) and Filter menus replacing the in-list toggle row. The context menu adds New File/New Folder (folders) and Show in Finder. The redundant "File" section is gone. |
| Frontmatter | Inspector rows: switches for booleans, inline date pickers, wrapping tag chips, a multicolor warning for invalid YAML, selectable raw YAML. |
| Settings | System Settings idiom: grouped forms, sections, explanatory footers, and value-then-stepper rows. |
| Banners | Missing file, uncertain save, and workspace recovery banners use `NoticeBar`. |
| Workspace Search | Appearance only: filled search-field capsule, compact option toggles, Xcode Find-navigator style file headers (name, dimmed folder, count badge). |
| Preview CSS | Apple system palette. Dark background is `#1e1e1e` so it matches the editor. Xcode Default (Light/Dark) syntax colors replace highlight.js `github.css`, which painted a white nested box inside every code block in dark mode. |

## Deferred until in-flight PRs merge

These were left untouched on purpose, to avoid conflicts. Fold each into the named PR or
do it right after it merges.

### Main window (`WorkspaceWindow`, `AppState`): after #139 B1 / C

Do these as part of the per-window scene and menu work. Each window then owns its title,
toolbar, and banners.

1. **Drop `DocumentHeader`.** The window title, document proxy icon (`representedURL`), and
   edited dot (`isDocumentEdited`) already say the same thing. Move the parent path and
   file kind into `navigationSubtitle`.
2. **Toolbar per HIG.** Put a sidebar toggle at `.navigation`. Show the layout mode as a
   segmented control (Source / Split / WYSIWYG once it ships) with the ⌘⇧P cycle kept.
   Open and Save live in the File menu; Apple's document editors do not repeat them in the
   toolbar.
3. **Empty state.** `ContentUnavailableView` with **Open…** and the recent items.
4. **Status bar.** Keep it, but use monospaced digits, and add a Pages-style word-count
   popover if wanted.
5. **Banners.** Move `ExternalChangeBanner` and `WYSIWYGFallbackBanner` to `NoticeBar` so
   every editor notice matches.
6. **Native sidebar (R17).** Spike an `NSSplitViewController` sidebar item (floating Liquid
   Glass sidebar, user-resizable, ⌃⌘S) in a separate PR, with launch-stability evidence.
   Do not attempt it inside the window-state split.

### Find / Replace bar and Edit menu: after #151

Restyle the bar to read like Safari's or Xcode's: bar material, a search field with the
match count inside it, a previous/next segmented control, and a trailing **Done**. Keep
#151's focus, IME, and responder contracts as they are.

### File menu and export banner: after #147 and its follow-up (20a)

Show export progress and outcome with `NoticeBar` (or the window's toolbar progress)
instead of a bespoke banner. Menu titles follow the HIG ellipsis rule ("Export as PDF…",
"Print…").
