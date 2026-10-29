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
    }
}
