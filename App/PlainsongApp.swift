import AppKit
import EditorKit
import MarkdownCore
import SwiftUI

@MainActor
func makePlainsongAppState(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> AppState {
    #if DEBUG
        if environment[DebugWorkspaceSearchFixture.environmentKey]?.isEmpty == false
            || environment[DebugEditorFindFixture.environmentKey]?.isEmpty == false
        {
            return DebugWorkspaceSearchFixture.makeIsolatedAppState()
        }
    #endif
    return AppState()
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
    @StateObject private var inspectorMenuState = InspectorMenuState.shared

    init() {
        let state = makePlainsongAppState()
        _appState = StateObject(wrappedValue: state)
        WorkspaceSceneReopener.shared.remember(state)
        _menuBarState = StateObject(wrappedValue: MenuBarState())
        // Find menu actions → the originating editor's window (§5.1).
        EditorFindCommandDelivery.installHooks()
    }

    var body: some Scene {
        WindowGroup(id: WorkspaceSceneReopener.sceneID) {
            WindowFacadeRoot(owner: appState)
                .tint(.accentColor)
                .onAppear {
                    appDelegate.appState = appState
                }
        }
        .defaultSize(width: 1280, height: 800)
        .handlesExternalEvents(matching: ["*"])
        .commands {
            if #available(macOS 27.0, *) { SidebarCommands() }
            InspectorToggleCommands(menuState: inspectorMenuState)
            PlainsongCommands(menuBarState: menuBarState)
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
