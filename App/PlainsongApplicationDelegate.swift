import AppKit

@MainActor
final class PlainsongApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var appState: AppState? {
        didSet {
            PlainsongAppServices.appState = appState
            #if DEBUG
                openDebugWorkspaceIfRequested()
            #endif
        }
    }

    func applicationWillFinishLaunching(_: Notification) {
        PlainsongApplicationSendEventHook.installIfNeeded()
    }

    func applicationDidFinishLaunching(_: Notification) {
        PlainsongApplicationSendEventHook.installIfNeeded()
    }

    func applicationShouldTerminate(
        _: NSApplication
    ) -> NSApplication.TerminateReply {
        guard let appState else { return .terminateNow }
        return appState.prepareForTermination() ? .terminateNow : .terminateCancel
    }

    /// Debug-only: `PLAINSONG_DEBUG_OPEN_WORKSPACE=/path` opens a folder after `appState` is
    /// wired so keyboard smoke can run without a Powerbox panel (container paths preferred).
    private func openDebugWorkspaceIfRequested() {
        #if DEBUG
            guard let path = ProcessInfo.processInfo.environment["PLAINSONG_DEBUG_OPEN_WORKSPACE"],
                  !path.isEmpty,
                  let appState
            else {
                return
            }
            let url = URL(fileURLWithPath: path, isDirectory: true)
            DispatchQueue.main.async {
                appState.openExternalFile(url)
            }
        #endif
    }
}
