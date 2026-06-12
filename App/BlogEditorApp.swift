import AppKit
import SwiftUI

/// App entry point. Scenes only — state lives in `AppState` (agent.md §4).
@main
struct BlogEditorApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            WorkspaceWindow()
                .environmentObject(appState)
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
                Button("Open File...") {
                    appState.openFile()
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    appState.save()
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!appState.canSave)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase != .active else { return }
            appState.flushAutosaveIfNeeded()
        }

        Settings {
            SettingsView()
        }
    }
}
