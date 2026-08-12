import AppKit

@MainActor
final class PlainsongApplicationDelegate: NSObject, NSApplicationDelegate {
    #if DEBUG
        private var didHandleDebugFixtureRequest = false
        private var debugEditorFindFixture: DebugEditorFindFixture.CreatedFixture?
        private var debugEditorFindCleanupToken: String?
        private var debugEditorFindCleanupRequestTimer: Timer?
        private var debugFixtureURL: URL?
    #endif

    weak var appState: AppState? {
        didSet {
            PlainsongAppServices.appState = appState
            #if DEBUG
                handleDebugFixtureRequestIfNeeded()
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
            _ = cleanUpDebugEditorFindFixtureIfNeeded()
            stopPollingForDebugEditorFindCleanupRequests()
            if let debugFixtureURL {
                try? FileManager.default.removeItem(at: debugFixtureURL)
            }
            DebugWorkspaceSearchFixture.clearIsolatedDefaults()
        #endif
    }

    func applicationShouldTerminate(
        _: NSApplication
    ) -> NSApplication.TerminateReply {
        if let appState, !appState.prepareForTermination() {
            return .terminateCancel
        }
        #if DEBUG
            guard cleanUpDebugEditorFindFixtureIfNeeded() else {
                return .terminateCancel
            }
        #endif
        return .terminateNow
    }

    /// Debug-only workspace entry points run once after `appState` is wired. The UI-test
    /// fixture is created by the sandboxed app inside its own container, then enters the same
    /// production workspace-open path without recording test state as a user recent item.
    private func handleDebugFixtureRequestIfNeeded() {
        #if DEBUG
            guard !didHandleDebugFixtureRequest, let appState else { return }

            if let fixtureIdentifier = ProcessInfo.processInfo.environment[
                DebugEditorFindFixture.environmentKey
            ], !fixtureIdentifier.isEmpty {
                handleDebugEditorFindFixtureRequest(
                    fixtureIdentifier,
                    appState: appState
                )
                return
            }

            if let fixtureIdentifier = ProcessInfo.processInfo.environment[
                DebugWorkspaceSearchFixture.environmentKey
            ], !fixtureIdentifier.isEmpty {
                handleDebugWorkspaceSearchFixtureRequest(
                    fixtureIdentifier,
                    appState: appState
                )
                return
            }

            guard let path = ProcessInfo.processInfo.environment["PLAINSONG_DEBUG_OPEN_WORKSPACE"],
                  !path.isEmpty
            else {
                return
            }
            didHandleDebugFixtureRequest = true
            let url = URL(fileURLWithPath: path, isDirectory: true)
            Task { @MainActor in
                await Task.yield()
                appState.openExternalFile(url)
            }
        #endif
    }

    #if DEBUG
        private func handleDebugEditorFindFixtureRequest(
            _ fixtureIdentifier: String,
            appState: AppState
        ) {
            didHandleDebugFixtureRequest = true
            do {
                let fixture = try DebugEditorFindFixture.create(
                    identifier: fixtureIdentifier
                )
                debugEditorFindFixture = fixture
                debugEditorFindCleanupToken = ProcessInfo.processInfo.environment[
                    DebugEditorFindFixture.cleanupTokenEnvironmentKey
                ]
                startPollingForDebugEditorFindCleanupRequests()
                Task { @MainActor in
                    await Task.yield()
                    appState.openDebugUITestWorkspaceFixture(fixture.workspaceURL)
                }
            } catch {
                assertionFailure("Could not create Debug editor-find fixture: \(error)")
            }
        }

        private func handleDebugWorkspaceSearchFixtureRequest(
            _ fixtureIdentifier: String,
            appState: AppState
        ) {
            didHandleDebugFixtureRequest = true
            do {
                let url = try DebugWorkspaceSearchFixture.create(
                    identifier: fixtureIdentifier
                )
                debugFixtureURL = url
                Task { @MainActor in
                    await Task.yield()
                    appState.openDebugUITestWorkspaceFixture(url)
                }
            } catch {
                assertionFailure("Could not create Debug workspace-search fixture: \(error)")
            }
        }

        private func startPollingForDebugEditorFindCleanupRequests() {
            guard debugEditorFindCleanupRequestTimer == nil,
                  let debugEditorFindCleanupToken,
                  !debugEditorFindCleanupToken.isEmpty
            else {
                return
            }
            let timer = Timer(
                timeInterval: 0.05,
                target: self,
                selector: #selector(handleDebugEditorFindCleanupRequestTimer(_:)),
                userInfo: nil,
                repeats: true
            )
            RunLoop.main.add(timer, forMode: .common)
            debugEditorFindCleanupRequestTimer = timer
        }

        private func stopPollingForDebugEditorFindCleanupRequests() {
            debugEditorFindCleanupRequestTimer?.invalidate()
            debugEditorFindCleanupRequestTimer = nil
        }

        /// The UI runner supplies only the nonce-bound identity for its own app-created
        /// handle. The app still owns cleanup authority and enters normal termination.
        @objc private func handleDebugEditorFindCleanupRequestTimer(
            _: Timer
        ) {
            guard let fixture = debugEditorFindFixture,
                  let cleanupToken = debugEditorFindCleanupToken,
                  let request = debugEditorFindCleanupPasteboard(
                      token: cleanupToken
                  ).string(
                      forType: NSPasteboard.PasteboardType(
                          DebugEditorFindFixture.cleanupRequestPasteboardType
                      )
                  ),
                  DebugEditorFindFixture.cleanupRequestMatches(
                      fixtureIdentifier: fixture.identifier,
                      cleanupToken: cleanupToken,
                      request: request
                  )
            else {
                return
            }
            NSApplication.shared.terminate(nil)
        }

        /// Graceful Quit cleanup is synchronous. A receipt is published only after the
        /// app-owned handle has verified that its exact no-follow fixture entry is absent.
        private func cleanUpDebugEditorFindFixtureIfNeeded() -> Bool {
            guard let fixture = debugEditorFindFixture else {
                return true
            }
            do {
                try fixture.remove()
            } catch {
                return false
            }

            if let token = debugEditorFindCleanupToken, !token.isEmpty {
                let pasteboard = debugEditorFindCleanupPasteboard(token: token)
                pasteboard.clearContents()
                let receipt = DebugEditorFindFixture.cleanupReceipt(
                    identifier: fixture.identifier,
                    token: token
                )
                guard pasteboard.setString(
                    receipt,
                    forType: NSPasteboard.PasteboardType(
                        DebugEditorFindFixture.cleanupReceiptPasteboardType
                    )
                ),
                    pasteboard.string(
                        forType: NSPasteboard.PasteboardType(
                            DebugEditorFindFixture.cleanupReceiptPasteboardType
                        )
                    ) == receipt
                else {
                    return false
                }
            }

            debugEditorFindFixture = nil
            debugEditorFindCleanupToken = nil
            stopPollingForDebugEditorFindCleanupRequests()
            return true
        }

        private func debugEditorFindCleanupPasteboard(
            token: String
        ) -> NSPasteboard {
            NSPasteboard(
                name: NSPasteboard.Name(
                    DebugEditorFindFixture.cleanupPasteboardName(token: token)
                )
            )
        }
    #endif
}
