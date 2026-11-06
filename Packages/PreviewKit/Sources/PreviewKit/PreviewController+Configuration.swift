@preconcurrency import WebKit

extension PreviewController {
    /// The one place the preview web view is configured. The SVG image-mode probe builds
    /// its web view here too, with only the `asset` handler swapped for a non-validating one.
    static func webViewConfiguration(
        assetSchemeHandler: any WKURLSchemeHandler,
        bridgeHandler: any WKScriptMessageHandler,
        contentRuleList: WKContentRuleList? = nil,
        websiteDataStore: WKWebsiteDataStore? = nil
    ) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        let userContentController = WKUserContentController()
        userContentController.add(bridgeHandler, name: "bridge")
        if let contentRuleList {
            userContentController.add(contentRuleList)
        }
        if let websiteDataStore {
            configuration.websiteDataStore = websiteDataStore
        }
        configuration.userContentController = userContentController
        configuration.setURLSchemeHandler(assetSchemeHandler, forURLScheme: "asset")
        configuration.preferences.isElementFullscreenEnabled = false
        return configuration
    }
}
