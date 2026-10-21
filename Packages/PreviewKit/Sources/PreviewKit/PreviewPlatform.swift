import WebKit
#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

enum PreviewPlatform {
    @MainActor
    static func configureTransparentBackground(_ webView: WKWebView) {
        #if os(macOS)
            webView.underPageBackgroundColor = .clear
            webView.wantsLayer = true
            webView.layer?.backgroundColor = NSColor.clear.cgColor
        #else
            webView.isOpaque = false
            webView.backgroundColor = .clear
            webView.scrollView.backgroundColor = .clear
            webView.underPageBackgroundColor = .clear
        #endif
    }

    @MainActor
    static func openExternalURL(_ url: URL) {
        #if os(macOS)
            NSWorkspace.shared.open(url)
        #else
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        #endif
    }
}
