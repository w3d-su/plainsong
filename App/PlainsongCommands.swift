import EditorKit
import MarkdownCore
import SwiftUI

/// App menu commands (File additions, Save, View, Format).
///
/// Enablement and labels observe `MenuBarState` — a deduplicated post-mutation snapshot —
/// instead of the high-churn `AppState`, so items revalidate reliably (the launch-time menu
/// build can no longer freeze its initial disabled states) without rebuilding the menu on
/// every search or statistics publish. Actions still call straight into `AppState` /
/// `EditorCommandDispatcher`; only what the menu *displays* routes through the snapshot.
struct PlainsongCommands: Commands {
    let appState: AppState
    @ObservedObject var menuBarState: MenuBarState

    private var snapshot: MenuBarSnapshot {
        menuBarState.snapshot
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New File") {
                appState.newFile()
            }
            .keyboardShortcut("n", modifiers: .command)

            Divider()

            Button("Open...") {
                appState.openFile()
            }
            .keyboardShortcut("o", modifiers: .command)

            Menu("Open Recent") {
                if snapshot.recentItemURLs.isEmpty {
                    Text("No Recent Items")
                } else {
                    ForEach(snapshot.recentItemURLs, id: \.self) { url in
                        Button(url.lastPathComponent) {
                            appState.openExternalFile(url)
                        }
                    }
                }
            }
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                appState.save()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!snapshot.canSave)
        }

        // Placed inside the system-provided View menu (sidebar/toolbar commands live there).
        // A separate `CommandMenu("View")` duplicated that menu's title, and SwiftUI's
        // key-equivalent dispatch swallowed ⇧⌘P/⇧⌘F without firing their actions while two
        // top-level menus shared one title (menu clicks kept working; only shortcuts died).
        CommandGroup(after: .sidebar) {
            Divider()

            Button(snapshot.layoutModeCommandTitle) {
                appState.cycleLayoutMode()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(!snapshot.hasOpenDocument)

            Button("Find in Workspace…") {
                appState.focusWorkspaceSearch()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(!snapshot.canUseWorkspaceSearch)
        }

        CommandMenu("Format") {
            formatButton("Bold", .format(.bold), key: "b", modifiers: .command)
            formatButton("Italic", .format(.italic), key: "i", modifiers: .command)
            formatButton(
                "Strikethrough",
                .format(.strikethrough),
                key: "x",
                modifiers: [.control, .command]
            )
            formatButton("Inline Code", .format(.inlineCode), key: "e", modifiers: .command)
            formatButton("Link", .format(.link), key: "k", modifiers: .command)

            Divider()

            formatButton("Heading 1", .format(.heading(level: 1)), key: "1", modifiers: .command)
            formatButton("Heading 2", .format(.heading(level: 2)), key: "2", modifiers: .command)
            formatButton("Heading 3", .format(.heading(level: 3)), key: "3", modifiers: .command)
            formatButton("Heading 4", .format(.heading(level: 4)), key: "4", modifiers: .command)
            formatButton("Heading 5", .format(.heading(level: 5)), key: "5", modifiers: .command)
            formatButton("Heading 6", .format(.heading(level: 6)), key: "6", modifiers: .command)
            formatButton("Paragraph", .format(.paragraph), key: "0", modifiers: .command)

            Divider()

            formatButton("Quote", .format(.quote), key: "q", modifiers: [.command, .shift])
            formatButton("Code Fence", .format(.codeFence), key: "k", modifiers: [.command, .shift])
            formatButton("Toggle Checkbox", .toggleCheckbox, key: "l", modifiers: .command)
            formatButton("Format Table", .formatTable, key: "f", modifiers: [.option, .command])
        }
    }

    private func formatButton(
        _ title: String,
        _ command: MarkdownEditCommand,
        key: KeyEquivalent,
        modifiers: EventModifiers
    ) -> some View {
        Button(title) {
            EditorCommandDispatcher.perform(command)
        }
        .keyboardShortcut(key, modifiers: modifiers)
        .disabled(!snapshot.hasOpenDocument)
    }
}
