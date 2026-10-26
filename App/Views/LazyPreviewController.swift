import PreviewKit
import SwiftUI

/// Owns a workspace's `PreviewController`, created the first time the preview pane is in the
/// view tree (`docs/decisions/2026-10-22-preview-webview-lifecycle.md`).
///
/// Creating the controller creates its `WKWebView`, and WebKit starts a WebContent process
/// for the bundled page, so a workspace kept in the source-only layout no longer pays for
/// one. Once created, the controller lives as long as the workspace view, as before: hiding
/// the pane keeps the page and its DOM, so showing it again renders nothing new.
///
/// Not observable on purpose: creating the controller during a body evaluation must not
/// publish a change from within that update.
@MainActor
final class LazyPreviewController: ObservableObject {
    private(set) var controller: PreviewController?

    /// The controller, created and passed to `configure` on the first call.
    func controller(configure: (PreviewController) -> Void) -> PreviewController {
        if let controller {
            return controller
        }
        let created = PreviewController()
        configure(created)
        controller = created
        return created
    }
}
