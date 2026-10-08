import AppKit
import SwiftUI

enum WorkspaceLayout {
    // 260 keeps a useful text column; Split also reserves a divider and 260 for Preview.
    static let editorMinimum: CGFloat = 260
    static let previewMinimum: CGFloat = 260
    // 320 sidebar + 1 divider + 521 Split + 58 system split-view/chrome allowance.
    static let windowMinimum: CGFloat = 900
    static func contentMinimum(preview: Bool) -> CGFloat {
        editorMinimum + (preview ? 1 + previewMinimum : 0)
    }
}

extension View {
    @ViewBuilder func workspaceFrameProbe(_ name: String) -> some View {
        #if DEBUG
            background(WorkspaceFrameProbe(name: name))
        #else
            self
        #endif
    }
}

#if DEBUG
    private struct WorkspaceFrameProbe: NSViewRepresentable {
        let name: String
        func makeNSView(context _: Context) -> NSView {
            let view = NSView()
            view.identifier = NSUserInterfaceItemIdentifier("plainsong.layout.\(name)")
            return view
        }

        func updateNSView(_: NSView, context _: Context) {}
    }
#endif
