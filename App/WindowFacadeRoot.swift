import AppKit
import SwiftUI

/// One workspace scene. A scene gets the app-owned façade whenever no open scene shows it,
/// including after its window closed (Dock reopen, Finder open). Every scene opened while the
/// owner is shown gets its own window and root context on the same registry. Until PR D2
/// such a scene refuses file and root opens and closes itself once `KeyWindowRouter.attach`
/// sees its window, so it cannot mirror the first window.
@MainActor
final class WindowFacadeHolder: ObservableObject {
    let facade: AppState

    init(owner: AppState) {
        if KeyWindowRouter.shared.claimOwner(owner) {
            facade = owner
        } else {
            facade = owner.makeSiblingFacade(admitsFileOperations: WindowOpenAdmission.admitsLaterScenes)
        }
    }
}

struct WindowFacadeRoot: View {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var holder: WindowFacadeHolder

    init(owner: AppState) {
        _holder = StateObject(wrappedValue: WindowFacadeHolder(owner: owner))
    }

    var body: some View {
        WorkspaceWindow()
            .environmentObject(holder.facade)
            .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
            .onOpenURL { url in
                holder.facade.openExternalFile(url)
            }
            .onAppear {
                WorkspaceSceneReopener.shared.installOpenScene {
                    openWindow(id: WorkspaceSceneReopener.sceneID)
                }
            }
    }
}

/// Reopens the one workspace scene when a File command or a Quit refusal has no window
/// to land on. Save, Find, and export keep using `menuTarget` and stay disabled.
@MainActor
final class WorkspaceSceneReopener {
    static let shared = WorkspaceSceneReopener()
    static let sceneID = "workspace"
    /// An `openWindow` that never attaches must not leave every later command queued.
    private static let openTimeout: Duration = .seconds(3)

    private weak var retainedOwner: AppState?
    private var openScene: (() -> Void)?
    /// File commands coalesce. Replaying several of them would stack Open panels.
    private var pendingFileCommand: ((AppState) -> Void)?
    /// Quit refusals stay beside the file command; a later Open must not drop one.
    private var pendingPresentations: [(AppState) -> Void] = []
    private var opening = false
    private var openGeneration: UInt = 0
    private var lastOpenExpired = false
    /// The first SwiftUI scene appears on its own. A command before that attach must
    /// wait for it instead of opening a second scene. Launch clears this on the next
    /// turn if no scene attached, so a missing launch window cannot wait forever.
    private var awaitingFirstScene = true

    private init() {}

    var knownOwner: AppState? {
        retainedOwner
    }

    func remember(_ owner: AppState) {
        retainedOwner = owner
    }

    func installOpenScene(_ action: @escaping () -> Void) {
        openScene = action
    }

    /// Runs `action` on the visible workspace window, or opens the workspace scene and
    /// runs it when that owner attaches. Several visible windows and no key window do
    /// not guess and do not open another window.
    func performFileCommand(openScene: @escaping () -> Void, action: @escaping (AppState) -> Void) {
        installOpenScene(openScene)
        guard let owner = retainedOwner else {
            if let target = KeyWindowRouter.shared.menuTarget(defaultFacade: nil),
               WindowOpenAdmission.admits(target.windowState),
               KeyWindowRouter.shared.hasAttachedWindow(target)
            {
                action(target)
            }
            return
        }
        let admitting = admittingFacades(of: owner)
        let attached = admitting.filter { KeyWindowRouter.shared.hasAttachedWindow($0) }
        if let target = KeyWindowRouter.shared.menuTarget(defaultFacade: nil),
           attached.contains(where: { $0 === target })
        {
            action(target)
            return
        }
        // Settings or About may be key. New, Open, and Open Recent still use the only
        // workspace window, and come forward so the result is not left behind it.
        if attached.count == 1 {
            let facade = attached[0]
            KeyWindowRouter.shared.focus(facade.windowState)
            action(facade)
            return
        }
        if attached.count > 1 { return }
        enqueue(fileCommand: action, owner: owner)
    }

    /// Shows `error` on a visible home window, or on the owner after its scene is opened
    /// again. Returns false when no opener is installed, so the caller can present locally.
    func reopenShowing(_ error: AppStateUserVisibleError) -> Bool {
        guard openScene != nil, let owner = retainedOwner else { return false }
        if let home = KeyWindowRouter.shared.home(for: owner.registry),
           KeyWindowRouter.shared.hasAttachedWindow(home)
        {
            home.presentedError = error
            KeyWindowRouter.shared.focus(home.windowState)
            return true
        }
        enqueue(presentation: { facade in
            facade.presentedError = error
            KeyWindowRouter.shared.focus(facade.windowState)
        }, owner: owner)
        return true
    }

    func noteAttached(_ facade: AppState) {
        awaitingFirstScene = false
        guard facade === retainedOwner, WindowOpenAdmission.admits(facade.windowState) else { return }
        lastOpenExpired = false
        guard opening else { return }
        openGeneration &+= 1
        opening = false
        let command = pendingFileCommand
        let presentations = pendingPresentations
        pendingFileCommand = nil
        pendingPresentations.removeAll()
        for presentation in presentations {
            presentation(facade)
        }
        command?(facade)
    }

    /// Called after launch. A claimed owner is still waiting for its scene to attach;
    /// only an unclaimed owner needs a scene request before that wait expires.
    func noteLaunchSettled() {
        guard awaitingFirstScene else { return }
        awaitingFirstScene = false
        guard opening, let owner = retainedOwner, canRequestScene(for: owner) else { return }
        openScene?()
    }

    #if DEBUG
        func resetForTesting() {
            retainedOwner = nil
            openScene = nil
            pendingFileCommand = nil
            pendingPresentations.removeAll()
            opening = false
            openGeneration &+= 1
            lastOpenExpired = false
            awaitingFirstScene = true
        }

        func expireOpeningForTesting() {
            expireOpening(generation: openGeneration)
        }
    #endif

    private func enqueue(
        fileCommand: ((AppState) -> Void)? = nil,
        presentation: ((AppState) -> Void)? = nil,
        owner: AppState
    ) {
        if let fileCommand {
            pendingFileCommand = fileCommand
        }
        if let presentation {
            pendingPresentations.append(presentation)
        }
        let shouldOpen = !opening && !awaitingFirstScene && canRequestScene(for: owner)
        if !opening {
            opening = true
            armOpenTimeout()
        }
        if shouldOpen {
            openScene?()
        }
    }

    private func armOpenTimeout() {
        openGeneration &+= 1
        let generation = openGeneration
        Task { @MainActor in
            try? await Task.sleep(for: Self.openTimeout)
            self.expireOpening(generation: generation)
        }
    }

    private func expireOpening(generation: UInt) {
        guard opening, openGeneration == generation else { return }
        opening = false
        pendingFileCommand = nil
        pendingPresentations.removeAll()
        lastOpenExpired = true
        awaitingFirstScene = false
    }

    private func admittingFacades(of owner: AppState) -> [AppState] {
        KeyWindowRouter.shared.facades(in: owner.registry).filter {
            WindowOpenAdmission.admits($0.windowState)
        }
    }

    private func hasAttachedAdmittingWindow(_ owner: AppState) -> Bool {
        admittingFacades(of: owner).contains { KeyWindowRouter.shared.hasAttachedWindow($0) }
    }

    private func canRequestScene(for owner: AppState) -> Bool {
        !hasAttachedAdmittingWindow(owner)
            && (!KeyWindowRouter.shared.isOwnerClaimed(owner) || lastOpenExpired)
    }
}
