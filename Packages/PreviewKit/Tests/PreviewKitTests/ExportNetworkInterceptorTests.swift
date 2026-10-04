import AppKit
import MarkdownCore
import Network
@testable import PreviewKit
import WebKit
import XCTest

/// E4 (HTML portion): a loopback HTTP CONNECT proxy is installed as the WebKit data store's
/// proxy, so every HTTP(S) request any web view in this process makes reaches it first. The
/// proxy records each connection and refuses the tunnel, so nothing leaves the machine.
///
/// The dedicated export controller (remote images forced off before its first render, as App
/// does even when the live-preview preference is on) must produce zero connections across the
/// render, discovery, finalization, and serialization, and when the exported document is
/// reopened. A positive control then renders the same document on a controller that allows
/// remote images, proving the interceptor sits in the request path.
@MainActor
final class ExportNetworkInterceptorTests: XCTestCase {
    private static let remoteHost = "plainsong-e4-intercept.invalid"

    func testExportIssuesNoHTTPRequestsEvenWhenTheLivePreviewAllowsRemoteImages() async throws {
        let proxy = try LoopbackProxyRecorder()
        let port = try await proxy.start()
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let previousProxies = dataStore.proxyConfigurations
        dataStore.proxyConfigurations = [
            ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: port)),
        ]
        addTeardownBlock { @MainActor in
            dataStore.proxyConfigurations = previousProxies
            proxy.stop()
        }
        let directory = try makeDirectory()
        try ExportRasterFixture.encoded(.png).write(to: directory.appendingPathComponent("local.png"))

        for (fileKind, source) in [(FileKind.markdown, Self.markdown), (FileKind.mdx, Self.mdx)] {
            let change = DocumentTextChange(
                text: source,
                version: 1,
                fileKind: fileKind,
                fileURL: directory.appendingPathComponent(fileKind == .mdx ? "post.mdx" : "post.md")
            )
            let export = try await makeExportController(dataStore: dataStore)
            // App's order (D1): forced off before the first render, whatever the live preference is.
            export.setAllowsRemoteImages(false)
            export.setTheme("light")
            export.setWorkspaceAssetRoot(directory)

            let render = await export.renderForExport(change)
            guard case let .completed(renderID) = render else {
                return XCTFail("Expected the export render to complete, got \(render)")
            }
            XCTAssertEqual(proxy.connections, [], "render issued HTTP(S) requests (\(fileKind))")

            let result = await export.exportHTML(matchingRenderID: renderID)
            guard case let .ready(html, _, _) = result else {
                return XCTFail("Expected ready HTML, got \(result)")
            }
            XCTAssertEqual(
                proxy.connections,
                [],
                "discovery, finalization, or serialization issued HTTP(S) requests (\(fileKind))"
            )
            XCTAssertTrue(html.contains("data:image/png;base64,"), "the local image must be embedded")
            // Ordinary links may keep http(s) targets (D3); no image or CSS sink may.
            XCTAssertFalse(html.contains("src=\"https://\(Self.remoteHost)"), "no remote image URL may survive")
            XCTAssertFalse(html.contains("src=\"http://\(Self.remoteHost)"), "no remote image URL may survive")
            XCTAssertFalse(html.contains("url(http"), "no remote CSS URL may survive")
            XCTAssertEqual(result.omittedImageCount, 2, "both remote images become placeholders (\(fileKind))")
            export.invalidate()

            try await reopen(html, dataStore: dataStore, fileKind: fileKind)
            XCTAssertEqual(proxy.connections, [], "reopening the export issued HTTP(S) requests (\(fileKind))")
        }

        // Positive control: the same document with remote images allowed reaches the proxy.
        let live = makeController(dataStore: dataStore)
        live.setAllowsRemoteImages(true)
        live.render(DocumentTextChange(
            text: Self.markdown,
            version: 1,
            fileKind: .markdown,
            fileURL: directory.appendingPathComponent("post.md")
        ))
        let deadline = Date().addingTimeInterval(20)
        while proxy.connections.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(
            proxy.connections.isEmpty,
            "the interceptor never saw the live preview's remote image, so it is not in the request path"
        )
        XCTAssertTrue(
            proxy.connections.contains { $0.contains(Self.remoteHost) },
            "control requests: \(proxy.connections)"
        )
    }

    private static let markdown = """
    # Interceptor

    ![local](local.png)

    ![remote https](https://\(remoteHost)/https.png)

    ![remote http](http://\(remoteHost)/http.png)

    [A remote link](https://\(remoteHost)/page) and https://\(remoteHost)/autolink

    $E=mc^2$

    ```swift
    let value = 1
    ```

    ```mermaid
    graph TD
    A-->B
    ```
    """

    private static let mdx = """
    import Card from "./Card"

    # Interceptor MDX

    ![local](local.png)

    <img src="https://\(remoteHost)/jsx.png" alt="jsx remote" />

    <Card href="https://\(remoteHost)/card">Card body</Card>

    ![remote https](https://\(remoteHost)/https.png)
    """

    private func reopen(_ html: String, dataStore: WKWebsiteDataStore, fileKind: FileKind) async throws {
        let handler = InterceptorDocumentSchemeHandler(html: html)
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: "plainsong-e4")
        configuration.websiteDataStore = dataStore
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let navigation = InterceptorNavigationWaiter()
        webView.navigationDelegate = navigation
        try webView.load(URLRequest(url: XCTUnwrap(URL(string: "plainsong-e4://document"))))
        let deadline = Date().addingTimeInterval(10)
        while !navigation.didFinish, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(navigation.didFinish)
        XCTAssertNil(navigation.failure)
        // Give any lazily started subresource a moment to reach the proxy.
        let rendered = try await webView.evaluateJavaScript(
            "document.querySelectorAll('img[src^=\"data:\"]').length"
        )
        XCTAssertEqual(rendered as? Int, 1)
        if fileKind == .markdown {
            let features = try await webView.evaluateJavaScript(
                "document.querySelectorAll('.katex, .hljs, .mermaid-rendered svg').length"
            )
            XCTAssertGreaterThan(features as? Int ?? 0, 0)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(handler.requests, ["plainsong-e4://document"])
    }

    private func previewIndexURL() -> URL {
        let testFile = URL(fileURLWithPath: #filePath)
        let repositoryRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repositoryRoot.appendingPathComponent("App/Resources/preview/index.html")
    }

    private func makeController(dataStore: WKWebsiteDataStore) -> PreviewController {
        let controller = PreviewController(previewIndexURL: previewIndexURL(), websiteDataStore: dataStore)
        controller.exportTimeoutNanoseconds = 30_000_000_000
        addTeardownBlock { @MainActor [weak controller] in controller?.invalidate() }
        return controller
    }

    private func makeExportController(dataStore: WKWebsiteDataStore) async throws -> PreviewController {
        let controller = try await PreviewController.makeHTMLExportController(
            previewIndexURL: previewIndexURL(), websiteDataStore: dataStore
        )
        controller.exportTimeoutNanoseconds = 30_000_000_000
        addTeardownBlock { @MainActor [weak controller] in controller?.invalidate() }
        return controller
    }

    private func makeDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("plainsong-e4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}

/// A loopback HTTP CONNECT proxy that records every connection's first request line and then
/// refuses it, so no request can reach a real network.
final class LoopbackProxyRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "plainsong.e4.loopback-proxy")
    private let lock = NSLock()
    private var recorded: [String] = []
    private var open: [NWConnection] = []
    private let listener: NWListener

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    /// One entry per accepted connection: its first request line (for example
    /// `CONNECT host:443 HTTP/1.1`), or a marker when no bytes arrived.
    var connections: [String] {
        lock.withLock { recorded }
    }

    func start() async throws -> NWEndpoint.Port {
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let resumed = LockedFlag()
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    if let port = listener.port, resumed.claim() {
                        continuation.resume(returning: port)
                    }
                case let .failed(error):
                    if resumed.claim() {
                        continuation.resume(throwing: error)
                    }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        lock.withLock { open }.forEach { $0.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        let index = lock.withLock {
            open.append(connection)
            recorded.append("<connection without a request line>")
            return recorded.count - 1
        }
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            if let data, let text = String(data: data, encoding: .utf8),
               let line = text.components(separatedBy: "\r\n").first
            {
                self?.lock.withLock { self?.recorded[index] = line }
            }
            let refusal = Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
            connection.send(content: refusal, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}

private final class InterceptorDocumentSchemeHandler: NSObject, WKURLSchemeHandler {
    private let html: String
    private let lock = NSLock()
    private var requested: [String] = []

    init(html: String) {
        self.html = html
    }

    var requests: [String] {
        lock.withLock { requested }
    }

    func webView(_: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        lock.withLock { requested.append(urlSchemeTask.request.url?.absoluteString ?? "") }
        guard let url = urlSchemeTask.request.url, url.host == "document" else {
            urlSchemeTask.didFailWithError(URLError(.resourceUnavailable))
            return
        }
        let data = Data(html.utf8)
        urlSchemeTask.didReceive(URLResponse(
            url: url,
            mimeType: "text/html",
            expectedContentLength: data.count,
            textEncodingName: "utf-8"
        ))
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_: WKWebView, stop _: WKURLSchemeTask) {}
}

private final class InterceptorNavigationWaiter: NSObject, WKNavigationDelegate {
    var didFinish = false
    var failure: String?

    func webView(_: WKWebView, didFinish _: WKNavigation!) {
        didFinish = true
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        failure = error.localizedDescription
        didFinish = true
    }

    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        failure = error.localizedDescription
        didFinish = true
    }
}
