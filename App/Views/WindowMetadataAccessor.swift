import AppKit
import SwiftUI

/// Registers the workspace window for export and mirrors document state onto it.
///
/// The title comes from `navigationTitle`/`navigationSubtitle`; this only owns the window
/// identifier, the proxy icon (`representedURL`), and the edited dot.
struct WindowMetadataAccessor: NSViewRepresentable {
    let representedURL: URL?
    let isDocumentEdited: Bool
    /// Shell-specific content floor. The `HStack` and split shells use different constants.
    let contentMinWidth: CGFloat
    /// Hands the hosting window to window-scoped chrome (the inspector's menu routing).
    var onWindow: (NSWindow) -> Void = { _ in }

    func makeNSView(context _: Context) -> MetadataView {
        let view = MetadataView()
        view.applyMetadata = applyMetadata(to:)
        return view
    }

    func updateNSView(_ nsView: MetadataView, context _: Context) {
        nsView.applyMetadata = applyMetadata(to:)
        nsView.applyMetadataLater()
    }

    private func applyMetadata(to window: NSWindow?) {
        guard let window else { return }
        if window.identifier != AppState.exportHTMLWorkspaceWindowIdentifier {
            window.identifier = AppState.exportHTMLWorkspaceWindowIdentifier
            NotificationCenter.default.post(name: AppState.exportHTMLWindowRegistered, object: window)
        }
        // Keep the content-independent floor on AppKit windows too (including hosted roots).
        if window.contentMinSize.width != contentMinWidth {
            window.contentMinSize = NSSize(width: contentMinWidth, height: 420)
        }
        window.representedURL = representedURL
        window.isDocumentEdited = isDocumentEdited
        onWindow(window)
    }

    final class MetadataView: NSView {
        var applyMetadata: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyMetadataLater()
        }

        func applyMetadataLater() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                applyMetadata?(window)
            }
        }
    }
}
