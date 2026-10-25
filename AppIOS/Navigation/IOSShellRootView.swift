import SwiftUI

/// Scene root. Compact width: `NavigationStack` with the file browser as root
/// and the document pushed on top (file navigation + source/preview toggle).
/// Regular width: `NavigationSplitView` sidebar + persistent detail, where the
/// document area still decides single-pane vs side-by-side from its *actual*
/// width — Split View and Stage Manager can shrink the detail below 900 pt.
///
/// All state lives in the per-scene `IOSShellSceneState`; this view only
/// forwards lifecycle (observe, background flush) and compact navigation.
struct IOSShellRootView: View {
    @ObservedObject var scene: IOSShellSceneState
    @ObservedObject var router: IOSShellActionRouter
    let recovery: IOSRecoveryController?

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase

    init(scene: IOSShellSceneState, recovery: IOSRecoveryController? = nil) {
        self.recovery = recovery
        _scene = ObservedObject(wrappedValue: scene)
        _router = ObservedObject(wrappedValue: IOSShellActionRouter(scene: scene))
    }

    init(scene: IOSShellSceneState, router: IOSShellActionRouter, recovery: IOSRecoveryController? = nil) {
        self.recovery = recovery
        _scene = ObservedObject(wrappedValue: scene)
        _router = ObservedObject(wrappedValue: router)
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                NavigationSplitView {
                    IOSWorkspaceBrowserView(scene: scene, recovery: recovery)
                } detail: {
                    IOSDocumentScreen(scene: scene, router: router)
                }
            } else {
                NavigationStack(path: $scene.navigationPath) {
                    IOSWorkspaceBrowserView(scene: scene, recovery: recovery)
                        .navigationDestination(for: IOSShellRoute.self) { route in
                            switch route {
                            case .document:
                                IOSDocumentScreen(scene: scene, router: router)
                            }
                        }
                }
            }
        }
        .onAppear { scene.startObserving() }
        .onDisappear { scene.stopObserving() }
        .onChange(of: scene.chrome.hasDocument) { _, hasDocument in
            // Compact only: popping back to Files after the last document
            // closes. Pushing is driven by the row tap itself so a no-op open
            // can't strand the user on a document screen.
            if !hasDocument {
                scene.navigationPath = []
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                scene.flushForBackground()
            }
        }
        .alert(
            scene.presentedError?.title ?? "Error",
            isPresented: Binding(
                get: { scene.presentedError != nil },
                set: {
                    isPresented in if !isPresented {
                        scene.dismissError()
                    }
                }
            ),
            presenting: scene.presentedError
        ) { _ in
            Button("OK", role: .cancel) { scene.dismissError() }
        } message: { error in
            Text(error.message)
        }
    }
}
