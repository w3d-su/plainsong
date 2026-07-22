import AppKit
import EditorKit
import MarkdownCore
import SwiftUI

@MainActor
private func makePlainsongAppState() -> AppState {
    AppState()
}

/// App entry point. Scenes only — state lives in `AppState` (agent.md §4).
@main
struct PlainsongApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @NSApplicationDelegateAdaptor(PlainsongApplicationDelegate.self)
    private var appDelegate
    @StateObject private var appState: AppState
    /// Menu enablement observes this deduplicated snapshot, never `AppState` directly
    /// (see `MenuBarState` for why the menu must not track high-churn publishes).
    @StateObject private var menuBarState: MenuBarState

    init() {
        let state = makePlainsongAppState()
        _appState = StateObject(wrappedValue: state)
        _menuBarState = StateObject(wrappedValue: MenuBarState(appState: state))
        // Publish state before the app-active Carbon ⇧⌘F handler can receive an event.
        PlainsongAppServices.appState = state
    }

    var body: some Scene {
        WindowGroup {
            WorkspaceWindow()
                .environmentObject(appState)
                .tint(.accentColor)
                .onAppear {
                    // Keep both the adaptor delegate and the Carbon key action in sync.
                    appDelegate.appState = appState
                    PlainsongAppServices.appState = appState
                }
                .onOpenURL { url in
                    appState.openExternalFile(url)
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    appState.flushAutosaveIfNeeded()
                }
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            PlainsongCommands(appState: appState, menuBarState: menuBarState)
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
