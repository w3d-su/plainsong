import Foundation
import WebKit

extension PreviewController {
    /// Export-only network policy, installed before the bundled page loads. Detached images can
    /// start a request as soon as innerHTML is parsed, before the pipeline rewrites their URLs.
    /// Export installs the live preview's blocking content rule and never swaps in the
    /// https-image exception. Compilation failure refuses export.
    public static func makeHTMLExportController(
        websiteDataStore: WKWebsiteDataStore? = nil
    ) async throws -> PreviewController {
        try await makeHTMLExportController(
            previewIndexURL: defaultPreviewIndexURL(), websiteDataStore: websiteDataStore ?? .nonPersistent()
        )
    }

    static func makeHTMLExportController(
        previewIndexURL: URL?,
        websiteDataStore: WKWebsiteDataStore? = nil
    ) async throws -> PreviewController {
        guard let rule = await PreviewRemoteImageRuleStore.rules().blockAll else {
            throw URLError(.resourceUnavailable)
        }
        try Task.checkCancellation()
        return PreviewController(
            previewIndexURL: previewIndexURL,
            contentRuleList: rule,
            websiteDataStore: websiteDataStore
        )
    }
}
