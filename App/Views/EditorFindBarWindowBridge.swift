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

    func attach(to window: NSWindow?) {
        let number = window?.windowNumber
        guard windowNumber != number else { return }
        Task { @MainActor [weak self] in
            guard let self, windowNumber != number else { return }
            windowNumber = number
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
