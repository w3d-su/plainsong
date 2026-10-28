import AppKit
import Foundation

/// Whether a window may open a file or workspace root. Production extra scenes refuse until
/// PR D2; hosted fixtures opt in. Stored off `WindowState` so the §3.2 property inventory
/// stays the B1 set (`docs/window-state-gates.md` §10 row C).
@MainActor
enum WindowOpenAdmission {
    /// Hosted fixtures set this so a second façade may open files. Production leaves it false.
    static var testingBypass = false
    private static var decisions: [ObjectIdentifier: Bool] = [:]

    static func set(_ window: WindowState, admits: Bool) {
        decisions[ObjectIdentifier(window)] = admits
    }

    static func admits(_ window: WindowState) -> Bool {
        decisions[ObjectIdentifier(window)] ?? true
    }

    static func resetForTesting() {
        testingBypass = false
        decisions = [:]
    }
}

/// App-global key-window map (`docs/window-state-gates.md` §5.1). One façade per workspace
/// window shares the process registry; menus and the ⇧⌘F hot key read the key façade here
/// and do not fall back to a main window while a non-workspace window is key.
@MainActor
final class KeyWindowRouter: ObservableObject {
    static let shared = KeyWindowRouter()

    /// Test pin. Production never sets it. Checked before the live key window so fixtures
    /// that have not mounted an `NSWindow` still address their façade.
    weak var testingPin: AppState?
    /// When true, `testingKeyWindow` replaces `NSApp.keyWindow` (including `nil`).
    var testingUsesKeyWindowOverride = false
    weak var testingKeyWindow: NSWindow?

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
    private var noticeOwners: [UUID: ObjectIdentifier] = [:]
    private var resignObserver: NSObjectProtocol?
    private var becomeObserver: NSObjectProtocol?
    /// The first workspace scene consumes the app-owned façade. Later scenes get a sibling.
    var didVendPrimaryScene = false
    /// Last window a refusal asked AppKit to focus. Tests assert this when no `NSWindow` exists.
    private(set) var focusedWindowState: WindowState?

    private init() {
        NSWindow.allowsAutomaticWindowTabbing = false
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

    func track(_ facade: AppState) {
        prune()
        let identifier = ObjectIdentifier(facade)
        if facades[identifier] == nil {
            facadeOrder.append(identifier)
        }
        facades[identifier] = FacadeBox(facade: facade)
    }

    func attach(_ window: NSWindow, to facade: AppState) {
        track(facade)
        window.tabbingMode = .disallowed
        let identifier = ObjectIdentifier(facade)
        if let existing = closeObservers[identifier] {
            NotificationCenter.default.removeObserver(existing)
        }
        windowsByFacade[identifier] = WindowBox(window: window)
        _ = WindowCloseInterceptor.install(on: window)
        closeObservers[identifier] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                KeyWindowRouter.shared.closeFacade(facade)
            }
        }
        objectWillChange.send()
        guard !WindowOpenAdmission.admits(facade.windowState) else { return }
        Task { @MainActor in
            self.closeAttachedWindow(of: facade)
        }
    }

    func isHome(_ facade: AppState) -> Bool {
        home(for: facade.registry) === facade
    }

    func home(for registry: AppDocumentRegistry) -> AppState? {
        facades(in: registry).first
    }

    func peers(of facade: AppState) -> [AppState] {
        facades(in: facade.registry)
    }

    func facades(in registry: AppDocumentRegistry) -> [AppState] {
        prune()
        return facadeOrder.compactMap { identifier in
            guard let facade = facades[identifier]?.facade, facade.registry === registry else {
                return nil
            }
            return facade
        }
    }

    /// First live façade of any registry. Menus use it only when AppKit has no key window.
    var firstLiveFacade: AppState? {
        prune()
        for identifier in facadeOrder {
            if let facade = facades[identifier]?.facade {
                return facade
            }
        }
        return nil
    }

    /// The façade whose commands run. A key non-workspace window yields `nil` unless a test
    /// pin is set. With no key window, the caller-supplied façade (or the first live one)
    /// is the single-window target.
    func menuTarget(defaultFacade: AppState?) -> AppState? {
        prune()
        if let testingPin { return testingPin }
        if let key = routedKeyWindow() {
            return facade(for: key)
        }
        if testingUsesKeyWindowOverride {
            return defaultFacade
        }
        if let designated = attachedWindows.first(where: \.isKeyWindow),
           let facade = facade(for: designated)
        {
            return facade
        }
        return defaultFacade ?? firstLiveFacade
    }

    func facade(for window: NSWindow?) -> AppState? {
        guard let window else { return nil }
        prune()
        return facadesInOrder.first { windowsByFacade[ObjectIdentifier($0)]?.window === window }
    }

    /// Finder/Dock/`onOpenURL` land on the frontmost admitting workspace window of this
    /// registry, never on a refused extra scene.
    func facadeForExternalOpen(fallback: AppState) -> AppState {
        prune()
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
        noticeOwners[id] = ObjectIdentifier(owner)
    }

    func forgetNotice(_ id: UUID) {
        noticeOwners[id] = nil
    }

    /// The façade that should show `id`, after its owner has closed.
    func noticeFacade(for id: UUID, registry: AppDocumentRegistry) -> AppState? {
        prune()
        if let key = noticeOwners[id], let owner = facades[key]?.facade, owner.registry === registry {
            return owner
        }
        return home(for: registry)
    }

    /// Moves the home role, and any error the closed façade was showing, to a surviving peer.
    func closeFacade(_ facade: AppState) {
        let identifier = ObjectIdentifier(facade)
        let wasTracked = facades[identifier]?.facade != nil || windowsByFacade[identifier] != nil
        guard wasTracked else { return }
        let next = peers(of: facade).first { $0 !== facade }
        if let error = facade.presentedError, let next {
            next.presentedError = error
            facade.presentedError = nil
            focusedWindowState = next.windowState
        }
        for (noticeID, owner) in noticeOwners where owner == identifier {
            noticeOwners[noticeID] = next.map { ObjectIdentifier($0) }
        }
        if let observer = closeObservers.removeValue(forKey: identifier) {
            NotificationCenter.default.removeObserver(observer)
        }
        facades[identifier] = nil
        windowsByFacade[identifier] = nil
        facadeOrder.removeAll { $0 == identifier }
        objectWillChange.send()
    }

    private var facadesInOrder: [AppState] {
        prune()
        return facadeOrder.compactMap { facades[$0]?.facade }
    }

    private var attachedWindows: [NSWindow] {
        windowsByFacade.values.compactMap(\.window)
    }

    private func routedKeyWindow() -> NSWindow? {
        if testingUsesKeyWindowOverride {
            return testingKeyWindow
        }
        return NSApp.keyWindow
    }

    private func prune() {
        facades = facades.filter { $0.value.facade != nil }
        facadeOrder.removeAll { facades[$0]?.facade == nil }
        windowsByFacade = windowsByFacade.filter { facades[$0.key]?.facade != nil }
    }

    private func noteKeyChange(resigned window: NSWindow?) {
        objectWillChange.send()
        guard let window, let facade = facade(for: window) else { return }
        facade.flushAutosaveAfterWindowResignedKey()
    }
}
