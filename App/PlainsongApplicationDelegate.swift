import AppKit

@MainActor
final class PlainsongApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var appState: AppState? {
        didSet { installFindInWorkspaceKeyMonitorIfNeeded() }
    }

    private var keyEquivalentMonitor: Any?

    func applicationDidFinishLaunching(_: Notification) {
        installFindInWorkspaceKeyMonitorIfNeeded()
    }

    func applicationShouldTerminate(
        _: NSApplication
    ) -> NSApplication.TerminateReply {
        guard let appState else { return .terminateNow }
        return appState.prepareForTermination() ? .terminateNow : .terminateCancel
    }

    /// Live evidence (2026-07-20): with the duplicate View menu fixed, ⇧⌘P and menu
    /// clicks for "Find in Workspace…" work, but ⇧⌘F still never fires the SwiftUI
    /// command action even though the item shows `cmd=F mods=Shift` and is enabled — the
    /// system View menu also binds letter F (Enter Full Screen). A local key monitor
    /// delivers the product shortcut reliably; the menu item remains for discoverability
    /// and click handling.
    ///
    /// Installed from both `applicationDidFinishLaunching` and `appState` assignment so a
    /// late SwiftUI `onAppear` wiring cannot leave the monitor absent.
    func installFindInWorkspaceKeyMonitorIfNeeded() {
        guard keyEquivalentMonitor == nil else { return }
        keyEquivalentMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handlePotentialFindInWorkspaceKey(event) ?? event
            }
        }
    }

    private func handlePotentialFindInWorkspaceKey(_ event: NSEvent) -> NSEvent? {
        guard PlainsongMenuKeyBinding.matchesFindInWorkspace(event) else {
            return event
        }
        guard let appState, appState.canUseWorkspaceSearch else {
            // Match disabled-menu behavior: do not consume when Search is unavailable.
            return event
        }
        appState.focusWorkspaceSearch()
        return nil
    }
}
