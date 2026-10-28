import AppKit
import SwiftUI

/// One workspace scene. The first scene uses the app-owned façade; every later scene gets
/// its own window and root context on the same registry. Until PR D2 a later scene refuses
/// file and root opens and closes itself, so it cannot mirror the first window.
@MainActor
final class WindowFacadeHolder: ObservableObject {
    let facade: AppState

    init(owner: AppState) {
        if !KeyWindowRouter.shared.didVendPrimaryScene {
            KeyWindowRouter.shared.didVendPrimaryScene = true
            facade = owner
        } else {
            facade = owner.makeSiblingFacade(admitsFileOperations: WindowOpenAdmission.testingBypass)
        }
    }

    func closeIfRefused() {
        guard !WindowOpenAdmission.admits(facade.windowState) else { return }
        KeyWindowRouter.shared.closeAttachedWindow(of: facade)
        KeyWindowRouter.shared.closeFacade(facade)
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
            .onAppear {
                Task { @MainActor in
                    holder.closeIfRefused()
                }
            }
            .onOpenURL { url in
                holder.facade.openExternalFile(url)
            }
    }
}
