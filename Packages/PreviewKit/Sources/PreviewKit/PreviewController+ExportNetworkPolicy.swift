import Foundation
import WebKit

extension PreviewController {
    /// Export-only network policy, installed before the bundled page loads. Detached images can
    /// start a request as soon as innerHTML is parsed, before the pipeline rewrites their URLs.
    /// A compiled WebKit rule blocks every HTTP(S) load at the loader, including that interval.
    /// Compilation failure refuses export. The live preview never receives this rule.
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
        let rule = try await exportNetworkRule()
        try Task.checkCancellation()
        return PreviewController(
            previewIndexURL: previewIndexURL,
            contentRuleList: rule,
            websiteDataStore: websiteDataStore
        )
    }

    /// The store keeps compiled lists on disk across launches, so only the first export
    /// compiles. The identifier is versioned: a changed rule needs a new identifier.
    static let exportNetworkRuleIdentifier = "plainsong-export-no-http-v1"
    static let exportNetworkRuleSource = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#

    private static func exportNetworkRule() async throws -> WKContentRuleList {
        if let stored = await storedExportNetworkRule() {
            return stored
        }
        return try await withCheckedThrowingContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: exportNetworkRuleIdentifier,
                encodedContentRuleList: exportNetworkRuleSource
            ) { rule, error in
                if let rule {
                    continuation.resume(returning: rule)
                } else {
                    continuation.resume(throwing: error ?? URLError(.resourceUnavailable))
                }
            }
        }
    }

    private static func storedExportNetworkRule() async -> WKContentRuleList? {
        await withCheckedContinuation { continuation in
            WKContentRuleListStore.default().lookUpContentRuleList(
                forIdentifier: exportNetworkRuleIdentifier
            ) { rule, _ in
                continuation.resume(returning: rule)
            }
        }
    }
}
