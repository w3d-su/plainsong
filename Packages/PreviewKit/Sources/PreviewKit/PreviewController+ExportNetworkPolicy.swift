import Foundation
import WebKit

extension PreviewController {
    /// Export-only network policy, installed before the bundled page loads. Detached images can
    /// start a request as soon as innerHTML is parsed, before the pipeline rewrites their URLs.
    /// A compiled WebKit rule blocks every HTTP(S) load at the loader, including that interval.
    /// Compilation failure refuses export. The live preview never receives this rule.
    public static func makeHTMLExportController() async throws -> PreviewController {
        try await makeHTMLExportController(
            previewIndexURL: defaultPreviewIndexURL(), websiteDataStore: .nonPersistent()
        )
    }

    static func makeHTMLExportController(
        previewIndexURL: URL?,
        websiteDataStore: WKWebsiteDataStore? = nil
    ) async throws -> PreviewController {
        let rule = try await exportNetworkRule()
        try Task.checkCancellation()
        return PreviewController(
            previewIndexURL: previewIndexURL,
            contentRuleList: rule,
            websiteDataStore: websiteDataStore
        )
    }

    private static func exportNetworkRule() async throws -> WKContentRuleList {
        try await withCheckedThrowingContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "plainsong-export-no-http-v1",
                encodedContentRuleList: #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
            ) { rule, error in
                if let rule {
                    continuation.resume(returning: rule)
                } else {
                    continuation.resume(throwing: error ?? URLError(.resourceUnavailable))
                }
            }
        }
    }
}
