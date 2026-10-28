import MarkdownCore
import Network
@testable import PreviewKit
import WebKit
import XCTest

/// S0 and S4. The mechanism probe serves a hostile SVG through the production
/// web-view settings without the validator, so a pass is WebKit image mode
/// rather than our reject path. Remote SVG is observed, not changed.
@MainActor
final class SVGImageModeProbeTests: XCTestCase {
    func testImageModeServesHostileSVGWithNoScriptAndNoNetwork() async throws {
        let proxy = try LoopbackProxyRecorder()
        let port = try await proxy.start()
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let previous = dataStore.proxyConfigurations
        dataStore.proxyConfigurations = [
            ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: port)),
        ]
        let pageURL = try writeProbePage()
        let handler = CountingAssetSchemeHandler(svg: Data(Self.hostileSVG.utf8))
        let bridge = BridgeCounter()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(bridge, name: "bridge")
        configuration.setURLSchemeHandler(handler, forURLScheme: "asset")
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.websiteDataStore = dataStore
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let navigation = ProbeNavigationDelegate(pageURL: pageURL)
        webView.navigationDelegate = navigation
        addTeardownBlock { @MainActor in
            webView.stopLoading()
            webView.navigationDelegate = nil
            dataStore.proxyConfigurations = previous
            proxy.stop()
            try? FileManager.default.removeItem(at: pageURL.deletingLastPathComponent())
        }

        _ = webView.loadFileURL(pageURL, allowingReadAccessTo: pageURL.deletingLastPathComponent())
        try await waitUntil("probe page") { navigation.didFinish }
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let widths = try await PreviewHostedTestWait.javascript(
            "Array.from(document.images).map((image) => image.naturalWidth)",
            in: webView
        )
        print(
            "SVG_PROBE os=\(ProcessInfo.processInfo.operatingSystemVersionString) " +
                "naturalWidths=\(String(describing: widths)) assetRequests=\(handler.requests) " +
                "bridgeMessages=\(bridge.messages.count) connections=\(proxy.connections)"
        )
        XCTAssertEqual(bridge.messages, [])
        XCTAssertEqual(proxy.connections, [])
        XCTAssertFalse(handler.requests.isEmpty)
        XCTAssertTrue(handler.requests.allSatisfy { $0.hasPrefix("asset://probe.svg") })
        XCTAssertEqual(webView.url?.standardizedFileURL, pageURL.standardizedFileURL)
    }

    func testRemoteSVGRequestFollowsTheExistingHTTPSImagePolicy() async throws {
        let proxy = try LoopbackProxyRecorder()
        let port = try await proxy.start()
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let previous = dataStore.proxyConfigurations
        dataStore.proxyConfigurations = [
            ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: port)),
        ]
        addTeardownBlock { @MainActor in
            dataStore.proxyConfigurations = previous
            proxy.stop()
        }
        let directory = try makeDirectory()
        let fileURL = directory.appendingPathComponent("post.md")
        let source = "![remote](https://\(Self.remoteHost)/diagram.svg)\n"

        let blocked = try makeController(dataStore: dataStore)
        blocked.setAllowsRemoteImages(false)
        let blockedRender = blocked.renderForTesting(DocumentTextChange(
            text: source, version: 1, fileKind: .markdown, fileURL: fileURL
        ))
        try await waitUntil("remote off render") { blocked.scrollDeliveryState.completedRenderID == blockedRender }
        try await Task.sleep(nanoseconds: 500_000_000)
        print("SVG_REMOTE_PROBE allow=false connections=\(proxy.connections)")
        XCTAssertEqual(proxy.connections, [])
        blocked.invalidate()

        let allowed = try makeController(dataStore: dataStore)
        allowed.setAllowsRemoteImages(true)
        allowed.render(DocumentTextChange(
            text: source, version: 1, fileKind: .markdown, fileURL: fileURL
        ))
        let deadline = Date().addingTimeInterval(20)
        while !proxy.connections.contains(where: { $0.contains(Self.remoteHost) }), Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        print(
            "SVG_REMOTE_PROBE os=\(ProcessInfo.processInfo.operatingSystemVersionString) " +
                "allow=true connections=\(proxy.connections)"
        )
        XCTAssertTrue(
            proxy.connections.contains { $0.contains(Self.remoteHost) },
            "remote SVG was not requested; connections=\(proxy.connections)"
        )
        allowed.invalidate()
    }

    func testProductionPreviewRendersAdmittedSVGAndDropsRejectedSVG() async throws {
        let workspace = try makeDirectory()
        let images = workspace.appendingPathComponent("content/images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let admitted = """
        <svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">
          <rect width="10" height="10" fill="#222"/>
        </svg>
        """
        try Data(admitted.utf8).write(to: images.appendingPathComponent("logo.svg"))
        try Data(Self.hostileSVG.utf8).write(to: images.appendingPathComponent("script.svg"))
        let controller = try makeController(dataStore: .nonPersistent())
        controller.installAssetReader(DirectPreviewAssetReader())
        controller.setWorkspaceAssetRoot(workspace)
        try await waitUntil("preview ready") { controller.isReady }
        controller.render(DocumentTextChange(
            text: "![ok](../images/logo.svg)\n\n![bad](../images/script.svg)\n",
            version: 1,
            fileKind: .markdown,
            fileURL: workspace.appendingPathComponent("content/posts/post.md")
        ))
        try await waitUntil("admitted svg painted") {
            let widths = try await PreviewHostedTestWait.javascript(
                "Array.from(document.images).map((image) => image.naturalWidth)",
                in: controller.webView
            ) as? [Int]
            return widths == [10, 0]
        }
    }

    func testHostedSVGLinkAndAssetNavigationStayOnThePreview() async throws {
        let controller = try makeController(dataStore: .nonPersistent())
        try await waitUntil("preview ready") { controller.isReady }
        let href = "images/diagram.svg"
        var clicked: String?
        controller.onLinkClicked = { clicked = $0 }
        controller.render(DocumentTextChange(
            text: "[diagram](\(href))\n",
            version: 1,
            fileKind: .markdown,
            fileURL: URL(fileURLWithPath: "/tmp/svg-nav/post.md")
        ))
        try await waitUntil("svg link rendered") {
            let text = try await PreviewHostedTestWait.javascript(
                "document.body.innerText",
                in: controller.webView
            ) as? String
            return text?.contains("diagram") == true
        }
        _ = try await PreviewHostedTestWait.javascript(
            "document.querySelector('a').click()",
            in: controller.webView
        )
        try await waitUntil("link reported") { clicked == href }
        let index = try XCTUnwrap(controller.webView.url?.standardizedFileURL)
        try controller.webView.load(URLRequest(url: XCTUnwrap(URL(string: "asset://images/diagram.svg"))))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(controller.webView.url?.standardizedFileURL, index)
        let text = try await PreviewHostedTestWait.javascript(
            "document.body.innerText",
            in: controller.webView
        ) as? String
        XCTAssertTrue(text?.contains("diagram") == true)
        XCTAssertEqual(
            PreviewController.navigationPolicy(
                for: URL(string: "asset://images/diagram.svg"),
                previewIndexURL: index
            ),
            .cancel
        )
    }

    private static let remoteHost = "plainsong-svg-remote.invalid"
    private static let hostileSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="32" height="32"
         onload="try{webkit.messageHandlers.bridge.postMessage({name:'svgProbe',payload:{kind:'onload'}})}catch(e){}">
      <script><![CDATA[
        try { webkit.messageHandlers.bridge.postMessage({name:'svgProbe', payload:{kind:'script'}}); } catch (e) {}
        try { fetch('https://plainsong-svg-probe.invalid/script'); } catch (e) {}
      ]]></script>
      <foreignObject width="32" height="32">
        <body xmlns="http://www.w3.org/1999/xhtml">
          <img src="https://plainsong-svg-probe.invalid/foreign-object" alt="">
          <iframe src="https://plainsong-svg-probe.invalid/foreign-frame"></iframe>
        </body>
      </foreignObject>
      <image href="https://plainsong-svg-probe.invalid/image-href" width="8" height="8"/>
      <use href="https://plainsong-svg-probe.invalid/use-href"/>
      <style>
        @import url("https://plainsong-svg-probe.invalid/import.css");
        rect { fill: url(https://plainsong-svg-probe.invalid/style-url); }
      </style>
      <rect width="8" height="8"/>
    </svg>
    """

    private func writeProbePage() throws -> URL {
        let html = try String(contentsOf: PreviewBundleFixture.indexURL(), encoding: .utf8)
        guard let marker = html.range(of: "content=\""),
              let end = html[marker.upperBound...].firstIndex(of: "\"")
        else {
            XCTFail("production CSP missing")
            throw ProbeFailure.missingCSP
        }
        let csp = String(html[marker.upperBound ..< end])
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("plainsong-svg-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let page = directory.appendingPathComponent("probe.html")
        let document = """
        <!doctype html>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <img src="asset://probe.svg" alt="probe">
        """
        try Data(document.utf8).write(to: page)
        return page.resolvingSymlinksInPath()
    }

    private func makeController(dataStore: WKWebsiteDataStore) throws -> PreviewController {
        let controller = try PreviewController(
            previewIndexURL: PreviewBundleFixture.indexURL(),
            websiteDataStore: dataStore
        )
        addTeardownBlock { @MainActor [controller] in controller.invalidate() }
        return controller
    }

    private func makeDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("plainsong-svg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func waitUntil(
        _ description: String,
        condition: @escaping @MainActor () async throws -> Bool
    ) async throws {
        try await PreviewHostedTestWait.until(description, condition: condition)
    }
}

private enum ProbeFailure: Error { case missingCSP }

private final class ProbeNavigationDelegate: NSObject, WKNavigationDelegate {
    let pageURL: URL
    private(set) var didFinish = false
    init(pageURL: URL) {
        self.pageURL = pageURL
    }

    func webView(
        _: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(PreviewController.navigationPolicy(
            for: navigationAction.request.url,
            previewIndexURL: pageURL
        ))
    }

    func webView(_: WKWebView, didFinish _: WKNavigation!) {
        didFinish = true
    }
}

private final class CountingAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    let svg: Data
    private let lock = NSLock()
    private var urls: [String] = []
    init(svg: Data) {
        self.svg = svg
    }

    var requests: [String] {
        lock.withLock { urls }
    }

    func webView(_: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        lock.withLock { urls.append(urlSchemeTask.request.url?.absoluteString ?? "") }
        guard let url = urlSchemeTask.request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: [
                      "Content-Type": "image/svg+xml",
                      "Content-Length": String(svg.count),
                  ]
              )
        else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(svg)
        urlSchemeTask.didFinish()
    }

    func webView(_: WKWebView, stop _: WKURLSchemeTask) {}
}

private final class BridgeCounter: NSObject, WKScriptMessageHandler {
    private let lock = NSLock()
    private var bodies: [String] = []
    var messages: [String] {
        lock.withLock { bodies }
    }

    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        lock.withLock { bodies.append(String(describing: message.body)) }
    }
}
