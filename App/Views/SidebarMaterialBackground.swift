import AppKit
import SwiftUI

/// The system sidebar material, so the fixed-width sidebar picks up the same translucency,
/// desktop tinting, and inactive-window dimming as Finder and Mail.
///
/// The sidebar stays inside the `HStack` shell (R17); only its background is native.
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
