import Combine
import Foundation

/// The menu-relevant facts, captured as one comparable value.
///
/// The main menu only needs these few facts; comparing them as a unit lets `MenuBarState`
/// drop every `AppState` publish that does not change what a menu item shows or whether it
/// is enabled.
struct MenuBarSnapshot: Equatable {
    var hasOpenDocument: Bool
    var canSave: Bool
    var canUseWorkspaceSearch: Bool
    var layoutModeCommandTitle: String
    var recentItemURLs: [URL]

    @MainActor
    init(appState: AppState) {
        hasOpenDocument = appState.hasOpenDocument
        canSave = appState.canSave
        canUseWorkspaceSearch = appState.canUseWorkspaceSearch
        layoutModeCommandTitle = appState.layoutModeCommandTitle
        recentItemURLs = appState.recentItemURLs
    }
}

/// Low-frequency menu enablement state observed by `PlainsongCommands`.
///
/// The app menu must not observe `AppState` directly: `objectWillChange` fires before the
/// mutation lands (a menu rebuilt at that instant re-reads pre-change values), and Phase 3
/// publishes at high frequency (search event streams, statistics), which thrashes NSMenu
/// rebuilds and made View-menu items stay stale-disabled or drop their key equivalents.
/// This object re-reads a `MenuBarSnapshot` on the next main run-loop pass after each
/// publish — post-mutation by construction — and republishes only when a menu-relevant
/// fact actually changed.
@MainActor
final class MenuBarState: ObservableObject {
    @Published private(set) var snapshot: MenuBarSnapshot

    private var subscription: AnyCancellable?

    init(appState: AppState) {
        snapshot = MenuBarSnapshot(appState: appState)
        subscription = appState.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self, weak appState] _ in
                MainActor.assumeIsolated {
                    guard let self, let appState else { return }
                    let next = MenuBarSnapshot(appState: appState)
                    if next != self.snapshot {
                        self.snapshot = next
                    }
                }
            }
    }
}
