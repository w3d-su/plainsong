import AppKit
import MarkdownCore
import Network
@testable import Plainsong
@testable import PreviewKit
import WebKit
import XCTest

@MainActor
final class ExportHTMLOfflineTests: XCTestCase {
    func testProductCommandAndWrittenHTMLIssueZeroHTTPRequestsWithLiveRemotePreferenceOn() async throws {
        let support = ExportHTMLCommandAppTests()
        let fixture = try support.makeFixture(text: """
        # Product offline export

        ![local](assets/pixel.png)

        ![HTTP](http://plainsong-app-export.invalid/a.png)

        ![HTTPS](https://plainsong-app-export.invalid/b.png)

        $E=mc^2$

        ```swift
        let value = 42
        ```

        ```mermaid
        graph TD
        A-->B
        ```
        """)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let proxy = try ExportHTTPProxyClient()
        let port = try XCTUnwrap(NWEndpoint.Port(rawValue: proxy.port))
        try await assertNoRequests(proxy)
        let proxies = [ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: port))]
        fixture.appState.preferences.setAllowsRemoteImages(true)
        let destination = fixture.exportsDirectory.appendingPathComponent("offline.html")
        fixture.appState.exportHTMLOperations.destinationChooser = { _ in
            fixture.appState.exportHTMLOperations.offscreenController?.webView.configuration.websiteDataStore
                .proxyConfigurations = proxies
            return destination
        }
        try await XCTUnwrap(fixture.appState.exportCurrentDocumentAsHTML()).value
        try await assertNoRequests(proxy)
        XCTAssertEqual(fixture.appState.exportHTMLNotice?.group, .exportedWithPlaceholders)
        XCTAssertTrue(fixture.appState.preferences.allowsRemoteImages)
        let html = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(html.contains("data:image/png;base64,"))
        XCTAssertFalse(html.contains("src=\"https://"))
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.websiteDataStore.proxyConfigurations = proxies
        let reopened = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let navigation = ExportOfflineNavigationWaiter()
        reopened.navigationDelegate = navigation
        reopened.loadFileURL(destination, allowingReadAccessTo: destination)
        let deadline = Date().addingTimeInterval(15)
        while !navigation.didFinish, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(navigation.didFinish)
        XCTAssertNil(navigation.error)
        let features = try await reopened.evaluateJavaScript(
            "JSON.stringify({image:document.images[0].naturalWidth, math:!!document.querySelector('.katex'), " +
                "code:!!document.querySelector('.hljs'), mermaid:!!document.querySelector('.mermaid-rendered svg')})"
        ) as? String
        let data = try XCTUnwrap(features?.data(using: .utf8))
        let rendered = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertGreaterThan(rendered["image"] as? Int ?? 0, 0)
        for feature in ["math", "code", "mermaid"] {
            XCTAssertEqual(rendered[feature] as? Bool, true)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        try await assertNoRequests(proxy)
        // Positive control proves this isolated proxy actually sees WebKit requests.
        let live = PreviewController(
            previewIndexURL: PreviewController.defaultPreviewIndexURL(),
            websiteDataStore: .nonPersistent()
        )
        defer { live.invalidate() }
        live.webView.configuration.websiteDataStore.proxyConfigurations = proxies
        live.setAllowsRemoteImages(true)
        _ = await live.renderForExport(DocumentTextChange(
            text: "![control](https://plainsong-app-export.invalid/control.png)", version: 1,
            fileKind: .markdown, fileURL: fixture.session.fileURL
        ))
        let controlDeadline = Date().addingTimeInterval(10)
        var requests = try await proxy.requests()
        while requests.isEmpty, Date() < controlDeadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            requests = try await proxy.requests()
        }
        XCTAssertTrue(requests.contains { $0.contains("plainsong-app-export.invalid") })
    }

    private func assertNoRequests(_ proxy: ExportHTTPProxyClient) async throws {
        let requests = try await proxy.requests()
        XCTAssertEqual(requests, [])
    }
}

private final class ExportOfflineNavigationWaiter: NSObject, WKNavigationDelegate {
    var didFinish = false
    var error: String?
    func webView(_: WKWebView, didFinish _: WKNavigation!) {
        didFinish = true
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        self.error = error.localizedDescription
        didFinish = true
    }

    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        self.error = error.localizedDescription
        didFinish = true
    }
}
