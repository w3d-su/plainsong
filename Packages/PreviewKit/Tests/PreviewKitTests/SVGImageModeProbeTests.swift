import MarkdownCore
import Network
@testable import PreviewKit
import WebKit
import XCTest

/// S0 and S4. The mechanism probe serves hostile SVGs through the production web-view
/// configuration (`PreviewController.webViewConfiguration`) with a non-validating `asset`
/// handler, so a pass is WebKit image mode rather than our reject path. Every sample is
/// well-formed and paints, so "no script, no network" cannot be a decode failure.
/// Remote SVG is observed, not changed.
@MainActor
final class SVGImageModeProbeTests: XCTestCase {
    func testImageModePaintsHostileSVGsWithNoScriptAndNoNetwork() async throws {
        let proxy = try LoopbackProxyRecorder()
        let port = try await proxy.start()
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let previous = dataStore.proxyConfigurations
        dataStore.proxyConfigurations = [
            ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: port)),
        ]
        var samples = SVGProbeFixtures.hostileSamples
        samples["e2e-rejected"] = SVGProbeFixtures.rejectedButPaintableSVG
        let pageURL = try SVGProbeFixtures.writeProbePage(names: samples.keys.sorted())
        let handler = CountingAssetSchemeHandler(svgs: samples.mapValues { Data($0.utf8) })
        let bridge = BridgeCounter()
        let (webView, navigation) = makeProbeWebView(
            handler: handler,
            bridge: bridge,
            dataStore: dataStore,
            page: pageURL
        )
        addTeardownBlock { @MainActor in
            dataStore.proxyConfigurations = previous
            proxy.stop()
        }

        _ = webView.loadFileURL(pageURL, allowingReadAccessTo: pageURL.deletingLastPathComponent())
        try await waitUntil("probe page") { navigation.didFinish }
        let widthsScript = """
        Object.fromEntries(Array.from(document.querySelectorAll('img.sample'))
          .map((image) => [image.id, image.complete ? image.naturalWidth : -1]))
        """
        var widths: [String: Int] = [:]
        try await waitUntil("every hostile sample painted") {
            widths = try await PreviewHostedTestWait.javascript(widthsScript, in: webView) as? [String: Int] ?? [:]
            return widths.count == samples.count && widths.values.allSatisfy { $0 > 0 }
        }
        // Controls: the bridge and the proxy both observe what the page itself does.
        try await waitUntil("bridge and proxy controls") {
            bridge.messages.contains { $0.contains("probeControl") } &&
                proxy.connections.contains { $0.contains(SVGProbeFixtures.controlHost) }
        }
        // Give a late script or subresource load time to show up before the negative checks.
        try await Task.sleep(nanoseconds: 500_000_000)
        print(
            "SVG_PROBE os=\(ProcessInfo.processInfo.operatingSystemVersionString) " +
                "naturalWidths=\(widths.sorted { $0.key < $1.key }) assetRequests=\(handler.requests.count) " +
                "bridgeMessages=\(bridge.messages.count) connections=\(proxy.connections)"
        )
        var expected = Dictionary(uniqueKeysWithValues: SVGProbeFixtures.hostileSamples.keys.map { ($0, 32) })
        expected["e2e-rejected"] = 10
        XCTAssertEqual(widths, expected)
        XCTAssertEqual(bridge.messages.filter { !$0.contains("probeControl") }, [])
        XCTAssertEqual(proxy.connections.filter { !$0.contains(SVGProbeFixtures.controlHost) }, [])
        XCTAssertEqual(
            Set(handler.requests.compactMap { URL(string: $0)?.host }),
            Set(samples.keys.map { "\($0).svg" })
        )
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
        try await waitUntil("remote off ready") { blocked.isReady }
        blocked.setAllowsRemoteImages(false)
        let blockedRender = blocked.renderForTesting(DocumentTextChange(
            text: source, version: 1, fileKind: .markdown, fileURL: fileURL
        ))
        try await waitUntil("remote off render") { blocked.scrollDeliveryState.completedRenderID == blockedRender }
        // Observe a bounded quiet window after render; the positive control below proves
        // this same proxy records a remote request when the policy permits it.
        try await Task.sleep(nanoseconds: 500_000_000)
        print("SVG_REMOTE_PROBE allow=false connections=\(proxy.connections)")
        XCTAssertEqual(proxy.connections, [])
        blocked.invalidate()

        let allowed = try makeController(dataStore: dataStore)
        try await waitUntil("remote on ready") { allowed.isReady }
        allowed.setAllowsRemoteImages(true)
        _ = allowed.renderForTesting(DocumentTextChange(
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

    /// The rejected file is the exact bytes S0 proves WebKit paints at width 10 without
    /// the validator, so width 0 here, with the handler reporting the failure, is the
    /// validator's doing and not a decode failure.
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
        try Data(SVGProbeFixtures.rejectedButPaintableSVG.utf8).write(to: images.appendingPathComponent("onload.svg"))
        XCTAssertEqual(
            SVGImageValidator.admission(of: Data(SVGProbeFixtures.rejectedButPaintableSVG.utf8)),
            .reject(.eventHandlerAttribute("onload"))
        )
        let controller = try makeController(dataStore: .nonPersistent())
        controller.installAssetReader(DirectPreviewAssetReader())
        controller.setWorkspaceAssetRoot(workspace)
        var failures: [PreviewAssetReadFailure] = []
        controller.assetSchemeHandler.onCurrentFailure = { failures.append($0) }
        try await waitUntil("preview ready") { controller.isReady }
        _ = controller.renderForTesting(DocumentTextChange(
            text: "![ok](../images/logo.svg)\n\n![bad](../images/onload.svg)\n",
            version: 1,
            fileKind: .markdown,
            fileURL: workspace.appendingPathComponent("content/posts/post.md")
        ))
        try await waitUntil("admitted svg painted and rejected svg failed") {
            let widths = try await PreviewHostedTestWait.javascript(
                "Array.from(document.images).map((image) => image.complete ? image.naturalWidth : -1)",
                in: controller.webView
            ) as? [Int]
            return widths == [10, 0] && failures == [.unsupportedType]
        }
    }

    func testHostedSVGLinkAndAssetNavigationStayOnThePreview() async throws {
        let controller = try makeController(dataStore: .nonPersistent())
        try await waitUntil("preview ready") { controller.isReady }
        let href = "images/diagram.svg"
        var clicked: String?
        controller.onLinkClicked = { clicked = $0 }
        _ = controller.renderForTesting(DocumentTextChange(
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
        var assetNavigationWasCancelled = false
        controller.onNavigationDecisionForTesting = { url, policy in
            if url?.scheme == "asset" {
                assetNavigationWasCancelled = policy == .cancel
            }
        }
        try controller.webView.load(URLRequest(url: XCTUnwrap(URL(string: "asset://images/diagram.svg"))))
        try await waitUntil("asset navigation cancelled") { assetNavigationWasCancelled }
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
    /// The production configuration with only the `asset` handler swapped.
    private func makeProbeWebView(
        handler: CountingAssetSchemeHandler,
        bridge: BridgeCounter,
        dataStore: WKWebsiteDataStore,
        page: URL
    ) -> (WKWebView, ProbeNavigationDelegate) {
        let configuration = PreviewController.webViewConfiguration(
            assetSchemeHandler: handler,
            bridgeHandler: bridge,
            websiteDataStore: dataStore
        )
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let navigation = ProbeNavigationDelegate(pageURL: page)
        webView.navigationDelegate = navigation
        addTeardownBlock { @MainActor in
            webView.stopLoading()
            webView.navigationDelegate = nil
            try? FileManager.default.removeItem(at: page.deletingLastPathComponent())
        }
        return (webView, navigation)
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
    let svgs: [String: Data]
    private let lock = NSLock()
    private var urls: [String] = []
    init(svgs: [String: Data]) {
        self.svgs = svgs
    }

    var requests: [String] {
        lock.withLock { urls }
    }

    /// Serves `asset://<name>.svg` unvalidated and without the response CSP.
    /// Image-mode isolation has to show up without that backstop. The media type also
    /// omits `charset`, so decoding does not depend on the production Content-Type.
    func webView(_: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        lock.withLock { urls.append(urlSchemeTask.request.url?.absoluteString ?? "") }
        guard let url = urlSchemeTask.request.url,
              let name = url.host?.replacingOccurrences(of: ".svg", with: ""),
              let svg = svgs[name],
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: [
                      "Content-Type": SVGImageValidator.mimeType,
                      "Content-Length": String(svg.count),
                      "X-Content-Type-Options": "nosniff",
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
