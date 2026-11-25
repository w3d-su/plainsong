import Foundation
import PreviewKit

/// Each window's live preview controllers, held weakly, so closing a window invalidates its
/// preview (`docs/window-state-gates.md` §6.2 step 5, W7 bullet 5) instead of waiting for
/// SwiftUI to release the view. Stored off `WindowState` so the §3.2 property inventory
/// stays the B1 set.
@MainActor
enum WindowPreviewControllers {
    private struct Entry {
        weak var window: WindowState?
        weak var controller: PreviewController?
    }

    private static var entries: [Entry] = []

    static func register(_ controller: PreviewController, for window: WindowState) {
        entries.removeAll { $0.window == nil || $0.controller == nil || $0.controller === controller }
        entries.append(Entry(window: window, controller: controller))
    }

    /// Invalidates `window`'s controllers: the bridge handler goes and no callback runs again.
    static func invalidate(for window: WindowState) {
        for entry in entries where entry.window === window {
            entry.controller?.invalidate()
        }
        entries.removeAll { $0.window == nil || $0.controller == nil || $0.window === window }
    }

    static func controllers(for window: WindowState) -> [PreviewController] {
        entries.compactMap { $0.window === window ? $0.controller : nil }
    }
}
