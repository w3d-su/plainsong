import AppKit
import EditorKit
import MarkdownCore
import SwiftUI

/// App entry point. Scenes only — state lives in `AppState` (agent.md §4).
@main
struct PlainsongApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            WorkspaceWindow()
                .environmentObject(appState)
                .tint(.accentColor)
                .onOpenURL { url in
                    appState.openExternalFile(url)
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    appState.flushAutosaveIfNeeded()
                }
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
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
                    if appState.recentItemURLs.isEmpty {
                        Text("No Recent Items")
                    } else {
                        ForEach(appState.recentItemURLs, id: \.self) { url in
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
                .disabled(!appState.canSave)
            }

            CommandMenu("View") {
                Button(appState.isPreviewVisible ? "Hide Preview" : "Show Preview") {
                    appState.togglePreview()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!appState.hasOpenDocument)
            }

            CommandMenu("Format") {
                Button("Bold") {
                    EditorCommandDispatcher.perform(.format(.bold))
                }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(!appState.hasOpenDocument)

                Button("Italic") {
                    EditorCommandDispatcher.perform(.format(.italic))
                }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(!appState.hasOpenDocument)

                Button("Strikethrough") {
                    EditorCommandDispatcher.perform(.format(.strikethrough))
                }
                .keyboardShortcut("x", modifiers: [.control, .command])
                .disabled(!appState.hasOpenDocument)

                Button("Inline Code") {
                    EditorCommandDispatcher.perform(.format(.inlineCode))
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(!appState.hasOpenDocument)

                Button("Link") {
                    EditorCommandDispatcher.perform(.format(.link))
                }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(!appState.hasOpenDocument)

                Divider()

                Button("Heading 1") {
                    EditorCommandDispatcher.perform(.format(.heading(level: 1)))
                }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(!appState.hasOpenDocument)

                Button("Heading 2") {
                    EditorCommandDispatcher.perform(.format(.heading(level: 2)))
                }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(!appState.hasOpenDocument)

                Button("Heading 3") {
                    EditorCommandDispatcher.perform(.format(.heading(level: 3)))
                }
                .keyboardShortcut("3", modifiers: .command)
                .disabled(!appState.hasOpenDocument)

                Button("Heading 4") {
                    EditorCommandDispatcher.perform(.format(.heading(level: 4)))
                }
                .keyboardShortcut("4", modifiers: .command)
                .disabled(!appState.hasOpenDocument)

                Button("Heading 5") {
                    EditorCommandDispatcher.perform(.format(.heading(level: 5)))
                }
                .keyboardShortcut("5", modifiers: .command)
                .disabled(!appState.hasOpenDocument)

                Button("Heading 6") {
                    EditorCommandDispatcher.perform(.format(.heading(level: 6)))
                }
                .keyboardShortcut("6", modifiers: .command)
                .disabled(!appState.hasOpenDocument)

                Button("Paragraph") {
                    EditorCommandDispatcher.perform(.format(.paragraph))
                }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(!appState.hasOpenDocument)

                Divider()

                Button("Quote") {
                    EditorCommandDispatcher.perform(.format(.quote))
                }
                .keyboardShortcut("q", modifiers: [.command, .shift])
                .disabled(!appState.hasOpenDocument)

                Button("Code Fence") {
                    EditorCommandDispatcher.perform(.format(.codeFence))
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(!appState.hasOpenDocument)

                Button("Toggle Checkbox") {
                    EditorCommandDispatcher.perform(.toggleCheckbox)
                }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(!appState.hasOpenDocument)

                Button("Format Table") {
                    EditorCommandDispatcher.perform(.formatTable)
                }
                .keyboardShortcut("f", modifiers: [.option, .command])
                .disabled(!appState.hasOpenDocument)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase != .active else { return }
            appState.flushAutosaveIfNeeded()
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
                .tint(.accentColor)
        }
    }
}
