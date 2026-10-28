import AppKit
import Combine
import Foundation

/// The menu-relevant facts, captured as one comparable value.
///
/// The main menu only needs these few facts; comparing them as a unit lets `MenuBarState`
/// drop every publish that does not change what a menu item shows or whether it is enabled.
struct MenuBarSnapshot: Equatable {
    var hasOpenDocument: Bool
    /// Edit ▸ Replace / Replace All: bar visible, row expanded, valid value. Display only;
    /// the action re-checks this and the key-window responder context itself.
    var canReplace: Bool
    var canSave: Bool
    var canExportHTML: Bool
    var canUseWorkspaceSearch: Bool
    var layoutModeCommandTitle: String
    var recentItemURLs: [URL]
    /// False while Settings, a panel, or an alert is key. Document commands stay disabled
    /// and must not fall back to the main window.
    var hasActiveWorkspaceWindow: Bool

    @MainActor
    init(appState: AppState) {
        self.init(appState: appState, recentItemURLs: appState.recentItemURLs)
    }

    @MainActor
    init(appState: AppState?, recentItemURLs: [URL]) {
        self.recentItemURLs = appState?.recentItemURLs ?? recentItemURLs
        guard let appState else {
            hasOpenDocument = false
            canReplace = false
            canSave = false
            canExportHTML = false
            canUseWorkspaceSearch = false
            layoutModeCommandTitle = "Show Preview"
            hasActiveWorkspaceWindow = false
            return
        }
        hasOpenDocument = appState.hasOpenDocument
        canReplace = appState.hasOpenDocument
            && appState.editorFindHost.ui.isReplaceRowActive
            && appState.editorFindHost.ui.replacementValidity == .valid
        canSave = appState.canSave
        canExportHTML = appState.canExportCurrentDocumentAsHTML
        canUseWorkspaceSearch = appState.canUseWorkspaceSearch
        layoutModeCommandTitle = appState.layoutModeCommandTitle
        hasActiveWorkspaceWindow = true
    }
}

/// Low-frequency menu enablement state observed by `PlainsongCommands`.
///
/// The app menu must not observe an `AppState` directly: `objectWillChange` fires before the
/// mutation lands, and a background window's publishes must not rebuild the menu. This
/// object re-subscribes when the key façade changes, re-reads a `MenuBarSnapshot` on the
/// next main run-loop pass, and republishes only when a menu-relevant fact changed.
@MainActor
final class MenuBarState: ObservableObject {
    @Published private(set) var snapshot: MenuBarSnapshot

    private var subscription: AnyCancellable?
    private var subscribedFacadeID: ObjectIdentifier?
    private var subscribedRegistryID: ObjectIdentifier?
    /// Tests pass one façade. Production follows the key window.
    private let overriddenFacade: AppState?

    init() {
        overriddenFacade = nil
        let target = KeyWindowRouter.shared.menuTarget(defaultFacade: nil)
        let registryFacade = target ?? KeyWindowRouter.shared.firstLiveFacade
        snapshot = MenuBarSnapshot(
            appState: target,
            recentItemURLs: registryFacade?.recentItemURLs ?? []
        )
        bind(target: target, registryFacade: registryFacade)
    }

    /// Observes `appState` only. Production menus use `init()` and the key-window router.
    init(appState: AppState) {
        overriddenFacade = appState
        snapshot = MenuBarSnapshot(appState: appState)
        bind(target: appState, registryFacade: appState)
    }

    private func bind(target: AppState?, registryFacade: AppState?) {
        subscribedFacadeID = target.map { ObjectIdentifier($0) }
        subscribedRegistryID = registryFacade.map { ObjectIdentifier($0.registry) }
        let windowChanges = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                             NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification,
                             NSWindow.willCloseNotification, AppState.exportHTMLWindowRegistered].map {
            NotificationCenter.default.publisher(for: $0).map { _ in () }.eraseToAnyPublisher()
        }
        let routerChanges = KeyWindowRouter.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher()
        var sources = windowChanges + [routerChanges]
        if let target {
            sources.append(target.objectWillChange.map { _ in () }.eraseToAnyPublisher())
        }
        if let registryFacade {
            sources.append(registryFacade.registry.objectWillChange.map { _ in () }.eraseToAnyPublisher())
            sources.append(registryFacade.registry.menuEnablementDidChange.eraseToAnyPublisher())
        }
        subscription = Publishers.MergeMany(sources)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh()
                }
            }
    }

    private func refresh() {
        let target = overriddenFacade ?? KeyWindowRouter.shared.menuTarget(defaultFacade: nil)
        let registryFacade = target ?? KeyWindowRouter.shared.firstLiveFacade
        let facadeID = target.map { ObjectIdentifier($0) }
        let registryID = registryFacade.map { ObjectIdentifier($0.registry) }
        if facadeID != subscribedFacadeID || registryID != subscribedRegistryID {
            bind(target: target, registryFacade: registryFacade)
        }
        let next = MenuBarSnapshot(
            appState: target,
            recentItemURLs: registryFacade?.recentItemURLs ?? []
        )
        if next != snapshot {
            snapshot = next
        }
    }
}
