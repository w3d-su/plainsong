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

    private weak var retainedOwner: AppState?
    private var openScene: (() -> Void)?
    private var pending: [(AppState) -> Void] = []
    private var opening = false
    /// The first SwiftUI scene appears on its own. A command before that attach must
    /// wait for it instead of opening a second scene.
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
        if attached.count == 1 {
            action(attached[0])
            return
        }
        if attached.count > 1 { return }
        pending.append(action)
        guard !awaitingFirstScene, admitting.isEmpty, !opening else {
            opening = true
            return
        }
        opening = true
        openScene()
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
        pending.append { facade in
            facade.presentedError = error
            KeyWindowRouter.shared.focus(facade.windowState)
        }
        guard !awaitingFirstScene, admittingFacades(of: owner).isEmpty, !opening else {
            opening = true
            return true
        }
        opening = true
        openScene?()
        return true
    }

    func noteAttached(_ facade: AppState) {
        awaitingFirstScene = false
        guard opening, facade === retainedOwner, WindowOpenAdmission.admits(facade.windowState) else { return }
        opening = false
        let actions = pending
        pending.removeAll()
        for action in actions {
            action(facade)
        }
    }

    #if DEBUG
        func resetForTesting() {
            retainedOwner = nil
            openScene = nil
            pending.removeAll()
            opening = false
            awaitingFirstScene = true
        }
    #endif

    private func admittingFacades(of owner: AppState) -> [AppState] {
        KeyWindowRouter.shared.facades(in: owner.registry).filter {
            WindowOpenAdmission.admits($0.windowState)
        }
    }
}
