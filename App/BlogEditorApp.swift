import SwiftUI

/// App entry point. Scenes only — state lives in `AppState` (agent.md §4).
@main
struct BlogEditorApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            WorkspaceWindow()
                .environmentObject(appState)
        }
        .defaultSize(width: 1100, height: 720)

        Settings {
            SettingsView()
        }
    }
}
