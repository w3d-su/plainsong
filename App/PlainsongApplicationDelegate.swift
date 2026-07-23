import AppKit

@MainActor
final class PlainsongApplicationDelegate: NSObject, NSApplicationDelegate {
    #if DEBUG
        private var didHandleDebugWorkspaceRequest = false
        private var debugWorkspaceFixtureURL: URL?
    #endif

    weak var appState: AppState? {
        didSet {
            PlainsongAppServices.appState = appState
            #if DEBUG
                handleDebugWorkspaceRequestIfNeeded()
            #endif
        }
    }

    func applicationDidBecomeActive(_: Notification) {
        PlainsongWorkspaceSearchHotKey.activate()
    }

    func applicationWillResignActive(_: Notification) {
        PlainsongWorkspaceSearchHotKey.deactivate()
    }

    func applicationWillTerminate(_: Notification) {
        PlainsongWorkspaceSearchHotKey.tearDown()
        #if DEBUG
            if let debugWorkspaceFixtureURL {
                try? FileManager.default.removeItem(at: debugWorkspaceFixtureURL)
            }
        #endif
    }

    func applicationShouldTerminate(
        _: NSApplication
    ) -> NSApplication.TerminateReply {
        guard let appState else { return .terminateNow }
        return appState.prepareForTermination() ? .terminateNow : .terminateCancel
    }

    /// Debug-only workspace entry points run once after `appState` is wired. The UI-test
    /// fixture is created by the sandboxed app inside its own container, then enters the same
    /// production workspace-open path without recording test state as a user recent item.
    private func handleDebugWorkspaceRequestIfNeeded() {
        #if DEBUG
            guard !didHandleDebugWorkspaceRequest, let appState else { return }

            if let fixtureIdentifier = ProcessInfo.processInfo.environment[
                DebugWorkspaceSearchFixture.environmentKey
            ], !fixtureIdentifier.isEmpty {
                didHandleDebugWorkspaceRequest = true
                do {
                    let url = try DebugWorkspaceSearchFixture.create(
                        identifier: fixtureIdentifier
                    )
                    debugWorkspaceFixtureURL = url
                    Task { @MainActor in
                        await Task.yield()
                        appState.openDebugWorkspaceSearchFixture(url)
                    }
                } catch {
                    assertionFailure("Could not create Debug workspace-search fixture: \(error)")
                }
                return
            }

            guard let path = ProcessInfo.processInfo.environment["PLAINSONG_DEBUG_OPEN_WORKSPACE"],
                  !path.isEmpty
            else {
                return
            }
            didHandleDebugWorkspaceRequest = true
            let url = URL(fileURLWithPath: path, isDirectory: true)
            Task { @MainActor in
                await Task.yield()
                appState.openExternalFile(url)
            }
        #endif
    }
}
