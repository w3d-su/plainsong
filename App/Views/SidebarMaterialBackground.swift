import AppKit
import SwiftUI

/// The system sidebar material for the pre-macOS 27 shell, so its fixed-width sidebar picks
/// up the same translucency, desktop tinting, and inactive-window dimming as Finder and Mail.
///
/// macOS 27+ uses `NavigationSplitView`, whose sidebar the system draws as Liquid Glass.
struct SidebarMaterialBackground: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_: NSVisualEffectView, context _: Context) {}
}
