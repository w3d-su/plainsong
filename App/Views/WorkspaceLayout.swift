import AppKit
import SwiftUI

enum WorkspaceLayout {
    // 260 keeps a useful text column; Split also reserves a divider and 260 for Preview.
    static let editorMinimum: CGFloat = 260
    static let previewMinimum: CGFloat = 260
    /// Fixed `HStack` shell (macOS 14–26): 256 pt sidebar + 1 pt divider + 521 pt Split
    /// content = 778, raised to 780. Half of a 1728 pt display is 864, so this floor tiles.
    static let fixedShellWindowMinimum: CGFloat = 780
    /// NavigationSplitView chrome on macOS 27, measured 2026-10-09 by
    /// `testSplitShellChromeMatchesTheRecordedConstant`: content 1400 − sidebar 320
    /// (minX 0) − document column 1080 (maxX 1400) = 0. The columns tile the content
    /// view; the separator does not add width.
    static let splitShellChrome: CGFloat = 0
    /// Widest sidebar + measured chrome + Split content minimum. Content-independent (R17).
    static let splitShellWindowMinimum: CGFloat = 320 + splitShellChrome + 521

    static func windowMinimum(splitShell: Bool) -> CGFloat {
        splitShell ? splitShellWindowMinimum : fixedShellWindowMinimum
    }

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
        func makeNSView(context _: Context) -> WorkspaceFrameProbeView {
            let view = WorkspaceFrameProbeView()
            view.identifier = NSUserInterfaceItemIdentifier("plainsong.layout.\(name)")
            return view
        }

        func updateNSView(_: WorkspaceFrameProbeView, context _: Context) {}
    }

    /// Debug-only frame marker. It must not participate in hit testing, or it can swallow
    /// the inspector handle's drag.
    private final class WorkspaceFrameProbeView: NSView {
        override func hitTest(_: NSPoint) -> NSView? {
            nil
        }
    }
#endif
