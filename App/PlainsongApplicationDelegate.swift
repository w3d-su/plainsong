import AppKit

@MainActor
final class PlainsongApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var appState: AppState?

    func applicationShouldTerminate(
        _: NSApplication
    ) -> NSApplication.TerminateReply {
        guard let appState else { return .terminateNow }
        return appState.prepareForTermination() ? .terminateNow : .terminateCancel
    }
}
