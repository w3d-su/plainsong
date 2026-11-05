import AppKit

/// A focus request that arrives while the app is inactive brings its window forward once the
/// app activates (`KeyWindowRouter.focus`). A Finder or Dock open of a file another window
/// shows (WD1) can reach the app just before AppKit activates it. A hosted test never
/// activates the app, so it never takes the developer's key window.
@MainActor
final class PendingWindowFocus {
    static let shared = PendingWindowFocus()
    /// Long enough for LaunchServices to finish activating the app after an open, short
    /// enough that a much later activation does not jump to an old window.
    private static let lifetime: Duration = .seconds(2)

    private weak var window: NSWindow?
    private var deadline: ContinuousClock.Instant?
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                PendingWindowFocus.shared.applyIfPending()
            }
        }
    }

    func request(_ window: NSWindow) {
        self.window = window
        deadline = .now + Self.lifetime
    }

    func cancel() {
        window = nil
        deadline = nil
    }

    var pendingWindow: NSWindow? {
        guard let deadline, ContinuousClock.now < deadline else { return nil }
        return window
    }

    private func applyIfPending() {
        let target = pendingWindow
        cancel()
        target?.makeKeyAndOrderFront(nil)
    }
}
