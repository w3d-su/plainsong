import AppKit
import SwiftUI

/// Publishes the `NSWindow` hosting one find bar, so its chrome-focus reports can be scoped
/// to that window.
///
/// Mirrors `WindowKeyStateTracker`: the window is learned from an AppKit attachment callback
/// and published on the **next** main-actor turn. Never publish synchronously from
/// `updateNSView` — mutating observed state during a SwiftUI view update is undefined and
/// trips "Modifying state during view update".
@MainActor
final class EditorFindBarWindowBridge: ObservableObject {
    @Published private(set) var windowNumber: Int?
    /// Last window actually published. Survives detach so bar teardown can still address the
    /// report it made for that window after the probe has already reported `nil`.
    private(set) var lastAttachedWindowNumber: Int?

    /// What the latest `attach` asked for. Compared against **this**, never against the
    /// published value: publication is a turn late, so `attach(A)` then `attach(nil)` would
    /// otherwise see `windowNumber == nil`, skip scheduling, and let A's in-flight task
    /// publish a window that is no longer attached.
    private var desiredWindowNumber: Int?
    private var generation: UInt64 = 0
    private var publishTask: Task<Void, Never>?

    func attach(to window: NSWindow?) {
        let number = window?.windowNumber
        guard desiredWindowNumber != number else { return }
        desiredWindowNumber = number
        generation &+= 1
        let scheduled = generation
        publishTask?.cancel()
        publishTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, scheduled == generation else { return }
            publishTask = nil
            guard windowNumber != number else { return }
            windowNumber = number
            if let number {
                lastAttachedWindowNumber = number
            }
        }
    }
}

/// Installs a zero-size AppKit probe that binds `EditorFindBarWindowBridge` to the host window.
struct EditorFindBarWindowReader: NSViewRepresentable {
    @ObservedObject var bridge: EditorFindBarWindowBridge

    func makeNSView(context _: Context) -> EditorFindBarWindowProbeView {
        let view = EditorFindBarWindowProbeView()
        view.bridge = bridge
        return view
    }

    func updateNSView(_ nsView: EditorFindBarWindowProbeView, context _: Context) {
        nsView.bridge = bridge
        // Safe from inside a view update only because `attach` defers the publish.
        bridge.attach(to: nsView.window)
    }

    static func dismantleNSView(_ nsView: EditorFindBarWindowProbeView, coordinator _: ()) {
        nsView.bridge?.attach(to: nil)
        nsView.bridge = nil
    }
}

final class EditorFindBarWindowProbeView: NSView {
    weak var bridge: EditorFindBarWindowBridge?

    override var intrinsicContentSize: NSSize {
        .zero
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        bridge?.attach(to: window)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        bridge?.attach(to: window)
    }
}
