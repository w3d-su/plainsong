import AppKit
import Foundation

/// Whether a window may open a file or workspace root. Production extra scenes refuse until
/// PR D2; hosted fixtures opt in. Stored off `WindowState` so the §3.2 property inventory
/// stays the B1 set (`docs/window-state-gates.md` §10 row C).
///
/// Fails closed: a window with no live decision refuses. Each entry holds its window weakly,
/// so a reused object address never inherits a released window's decision.
@MainActor
enum WindowOpenAdmission {
    private struct Decision {
        weak var window: WindowState?
        let admits: Bool
    }

    #if DEBUG
        /// Hosted fixtures set this so a later production scene may open files. Release builds
        /// do not have it.
        static var testingBypass = false
    #endif

    /// Whether a scene after the first is admitted. Always false outside DEBUG fixtures.
    static var admitsLaterScenes: Bool {
        #if DEBUG
            testingBypass
        #else
            false
        #endif
    }

    private static var decisions: [ObjectIdentifier: Decision] = [:]

    static func set(_ window: WindowState, admits: Bool) {
        decisions = decisions.filter { $0.value.window != nil }
        decisions[ObjectIdentifier(window)] = Decision(window: window, admits: admits)
    }

    static func admits(_ window: WindowState) -> Bool {
        guard let decision = decisions[ObjectIdentifier(window)], decision.window === window else {
            return false
        }
        return decision.admits
    }

    static func forget(_ window: WindowState) {
        decisions[ObjectIdentifier(window)] = nil
    }

    #if DEBUG
        static func resetForTesting() {
            testingBypass = false
            decisions = decisions.filter { $0.value.window != nil }
        }
    #endif
}

/// App-global key-window map (`docs/window-state-gates.md` §5.1). One façade per workspace
/// window shares the process registry; menus and the ⇧⌘F hot key read the key façade here
/// and do not fall back to a main window while a non-workspace window is key.
@MainActor
final class KeyWindowRouter: ObservableObject {
    static let shared = KeyWindowRouter()

    #if DEBUG
        /// Test pin. Production never sets it. Checked before the live key window so fixtures
        /// that have not mounted an `NSWindow` still address their façade.
        weak var testingPin: AppState?
        /// When true, `testingKeyWindow` replaces `NSApp.keyWindow` (including `nil`).
        var testingUsesKeyWindowOverride = false
        weak var testingKeyWindow: NSWindow?
    #endif

    private struct FacadeBox {
        weak var facade: AppState?
    }

    private struct WindowBox {
        weak var window: NSWindow?
    }

    private var facades: [ObjectIdentifier: FacadeBox] = [:]
    /// Insertion order. The first façade of a registry is its home window.
    private var facadeOrder: [ObjectIdentifier] = []
    private var windowsByFacade: [ObjectIdentifier: WindowBox] = [:]
    private var closeObservers: [ObjectIdentifier: NSObjectProtocol] = [:]
    private var noticeOwners: [UUID: FacadeBox] = [:]
    /// App-owned façades a scene currently shows. Released when that scene's window closes,
    /// so the next scene (Dock reopen, Finder open) gets the owner back.
    private var claimedOwners: [ObjectIdentifier: FacadeBox] = [:]
    /// Owners whose window closed. The next claim restores prompts from registry state.
    private var closedOwnersNeedingPromptRestore: Set<ObjectIdentifier> = []
    private var resignObserver: NSObjectProtocol?
    private var becomeObserver: NSObjectProtocol?
    /// Last window a user-initiated refusal asked AppKit to focus. Weak, so a closed window
    /// does not stay alive here and stay in the registry's connected windows.
    private(set) weak var focusedWindowState: WindowState?

    private init() {
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { notification in
            MainActor.assumeIsolated {
                let window = notification.object as? NSWindow
                KeyWindowRouter.shared.noteKeyChange(resigned: window)
            }
        }
        becomeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                KeyWindowRouter.shared.objectWillChange.send()
            }
        }
    }

    /// Native tabbing stays off until PR F. The app delegate calls this in
    /// `applicationWillFinishLaunching`, before any window exists.
    static func disableAutomaticWindowTabbing() {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    /// Gives a new scene the app-owned façade when no open scene shows it. Returns false while
    /// another scene shows it, so the caller builds a sibling instead. The owner keeps its
    /// document across a close, as the one shared `AppState` did before PR C.
    func claimOwner(_ owner: AppState) -> Bool {
        prune()
        let identifier = ObjectIdentifier(owner)
        guard claimedOwners[identifier]?.facade !== owner else { return false }
        claimedOwners[identifier] = FacadeBox(facade: owner)
        track(owner)
        if closedOwnersNeedingPromptRestore.remove(identifier) != nil {
            owner.restoreRecoveryPrompt(for: owner.shownSession)
        }
        return true
    }

    func track(_ facade: AppState) {
        prune()
        let identifier = ObjectIdentifier(facade)
        if facades[identifier]?.facade !== facade {
            facadeOrder.removeAll { $0 == identifier }
            facadeOrder.append(identifier)
        }
        facades[identifier] = FacadeBox(facade: facade)
    }

    /// Idempotent: SwiftUI reports the hosting window on every view update.
    func attach(_ window: NSWindow, to facade: AppState) {
        let identifier = ObjectIdentifier(facade)
        if isTracked(facade), windowsByFacade[identifier]?.window === window {
            return
        }
        track(facade)
        window.tabbingMode = .disallowed
        if let existing = closeObservers[identifier] {
            NotificationCenter.default.removeObserver(existing)
        }
        windowsByFacade[identifier] = WindowBox(window: window)
        _ = WindowCloseInterceptor.install(on: window)
        closeObservers[identifier] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak facade] _ in
            MainActor.assumeIsolated {
                guard let facade else { return }
                KeyWindowRouter.shared.closeFacade(facade)
            }
        }
        objectWillChange.send()
        // The one close path for a refused scene. It runs once the scene has a window.
        guard !WindowOpenAdmission.admits(facade.windowState) else { return }
        Task { @MainActor [weak window] in
            window?.performClose(nil)
        }
    }

    func isHome(_ facade: AppState) -> Bool {
        home(for: facade.registry) === facade
    }

    /// The first admitting façade of `registry`. A refused scene is never home: it closes
    /// itself, and errors or the foreground autosave must not land there.
    func home(for registry: AppDocumentRegistry) -> AppState? {
        let peers = facades(in: registry)
        return peers.first { WindowOpenAdmission.admits($0.windowState) } ?? peers.first
    }

    func peers(of facade: AppState) -> [AppState] {
        facades(in: facade.registry)
    }

    func facades(in registry: AppDocumentRegistry) -> [AppState] {
        facadesInOrder.filter { $0.registry === registry }
    }

    /// First live façade of any registry. Registry facts (recents) read it; commands never
    /// fall back to it.
    var firstLiveFacade: AppState? {
        facadesInOrder.first
    }

    /// The façade whose commands run. A key sheet or child window resolves to the workspace
    /// window it belongs to; any other key non-workspace window yields `nil`. With no key
    /// window the caller-supplied façade, or the only admitting façade, is the target.
    /// Several windows and no key window: no guess.
    func menuTarget(defaultFacade: AppState?) -> AppState? {
        prune()
        #if DEBUG
            if let testingPin { return testingPin }
        #endif
        if let key = routedKeyWindow() {
            return facade(for: key.sheetParent ?? key.parent ?? key)
        }
        if let defaultFacade { return defaultFacade }
        let admitting = facadesInOrder.filter { WindowOpenAdmission.admits($0.windowState) }
        return admitting.count == 1 ? admitting.first : nil
    }

    func facade(for window: NSWindow?) -> AppState? {
        guard let window else { return nil }
        return facadesInOrder.first { windowsByFacade[ObjectIdentifier($0)]?.window === window }
    }

    /// Finder/Dock/`onOpenURL` land on the frontmost admitting workspace window of this
    /// registry, never on a refused extra scene.
    func facadeForExternalOpen(fallback: AppState) -> AppState {
        let admitting = facades(in: fallback.registry).filter {
            WindowOpenAdmission.admits($0.windowState)
        }
        for window in NSApp.orderedWindows {
            if let facade = facade(for: window), admitting.contains(where: { $0 === facade }) {
                return facade
            }
        }
        if let home = home(for: fallback.registry), admitting.contains(where: { $0 === home }) {
            return home
        }
        return admitting.first ?? fallback
    }

    /// Brings `window` forward for a refusal the user caused (Quit). Background failures
    /// such as autosave do not call this: making another window key would send the user's
    /// next keystroke into a different document.
    func focus(_ window: WindowState) {
        focusedWindowState = window
        guard let facade = facadesInOrder.first(where: { $0.windowState === window }),
              let host = windowsByFacade[ObjectIdentifier(facade)]?.window
        else {
            return
        }
        // Hosted tests and an inactive dev session must not steal the owner's key window.
        guard NSApp.isActive else { return }
        host.makeKeyAndOrderFront(nil)
    }

    func closeAttachedWindow(of facade: AppState) {
        windowsByFacade[ObjectIdentifier(facade)]?.window?.performClose(nil)
    }

    func routeNotice(_ id: UUID, owner: AppState) {
        noticeOwners[id] = FacadeBox(facade: owner)
    }

    func forgetNotice(_ id: UUID) {
        noticeOwners[id] = nil
    }

    /// The façade that should show `id`, after its owner has closed.
    func noticeFacade(for id: UUID, registry: AppDocumentRegistry) -> AppState? {
        prune()
        if let owner = noticeOwners[id]?.facade, owner.registry === registry, isTracked(owner) {
            return owner
        }
        return home(for: registry)
    }

    /// Moves the home role, the foreground autosave, notices, and any error the closed façade
    /// was showing to a surviving admitting peer. A sibling's window leaves every registry
    /// inventory. The app-owned façade stays registered: it keeps its document for the next
    /// scene, as the single `AppState` did before PR C.
    func closeFacade(_ facade: AppState) {
        let identifier = ObjectIdentifier(facade)
        guard isTracked(facade) || windowsByFacade[identifier] != nil else { return }
        if isHome(facade) {
            // The shared foreground timer captured this façade. Give its document the
            // per-session background task before the home role moves.
            facade.moveCurrentAutosaveToBackground(for: facade.shownSession)
        }
        let next = peers(of: facade).first {
            $0 !== facade && WindowOpenAdmission.admits($0.windowState)
        }
        if let error = facade.presentedError, let next {
            next.presentedError = error
            facade.presentedError = nil
        }
        for (noticeID, owner) in noticeOwners where owner.facade === facade {
            noticeOwners[noticeID] = next.map { FacadeBox(facade: $0) }
        }
        if let observer = closeObservers.removeValue(forKey: identifier) {
            NotificationCenter.default.removeObserver(observer)
        }
        // Prompts are visible-window state. A closed window stays out of
        // isSaveBlockedByWindowPrompt; pending external text stays on the registry.
        // The app-owned facade stays registered so its document remains in termination
        // and autosave inventories, matching the single AppState before PR C.
        facade.windowState.externalChangePrompt = nil
        facade.windowState.missingFilePrompt = nil
        facade.windowState.indeterminateFileWriteReconciliationPrompt = nil
        let isOwner = claimedOwners.removeValue(forKey: identifier)?.facade === facade
        if isOwner {
            closedOwnersNeedingPromptRestore.insert(identifier)
        } else {
            facade.registry.unregister(facade.windowState)
            WindowOpenAdmission.forget(facade.windowState)
        }
        facades[identifier] = nil
        windowsByFacade[identifier] = nil
        facadeOrder.removeAll { $0 == identifier }
        objectWillChange.send()
    }

    #if DEBUG
        /// Clears every table and test hook. Hosted tests call it in `tearDown`.
        func resetForTesting() {
            testingPin = nil
            testingUsesKeyWindowOverride = false
            testingKeyWindow = nil
            for observer in closeObservers.values {
                NotificationCenter.default.removeObserver(observer)
            }
            closeObservers = [:]
            facades = [:]
            facadeOrder = []
            windowsByFacade = [:]
            noticeOwners = [:]
            claimedOwners = [:]
            closedOwnersNeedingPromptRestore = []
            focusedWindowState = nil
            objectWillChange.send()
        }
    #endif

    private func isTracked(_ facade: AppState) -> Bool {
        facades[ObjectIdentifier(facade)]?.facade === facade
    }

    private var facadesInOrder: [AppState] {
        prune()
        return facadeOrder.compactMap { facades[$0]?.facade }
    }

    private func routedKeyWindow() -> NSWindow? {
        #if DEBUG
            if testingUsesKeyWindowOverride {
                return testingKeyWindow
            }
        #endif
        return NSApp.keyWindow
    }

    /// Drops released façades and everything keyed by their identifiers, so a reused address
    /// never inherits a window, close observer, notice, or owner claim.
    private func prune() {
        for (identifier, box) in facades where box.facade == nil {
            if let observer = closeObservers.removeValue(forKey: identifier) {
                NotificationCenter.default.removeObserver(observer)
            }
            facades[identifier] = nil
        }
        facadeOrder.removeAll { facades[$0]?.facade == nil }
        windowsByFacade = windowsByFacade.filter { facades[$0.key]?.facade != nil }
        for identifier in closeObservers.keys where facades[identifier] == nil {
            if let observer = closeObservers.removeValue(forKey: identifier) {
                NotificationCenter.default.removeObserver(observer)
            }
        }
        claimedOwners = claimedOwners.filter { $0.value.facade != nil }
        noticeOwners = noticeOwners.filter { $0.value.facade != nil }
    }

    private func noteKeyChange(resigned window: NSWindow?) {
        objectWillChange.send()
        guard let window, let facade = facade(for: window) else { return }
        facade.flushAutosaveAfterWindowResignedKey()
    }
}
