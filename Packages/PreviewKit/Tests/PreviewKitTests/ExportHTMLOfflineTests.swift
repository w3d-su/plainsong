#if os(macOS)
    import AppKit
#endif
import MarkdownCore
@testable import PreviewKit
import WebKit
import XCTest

@MainActor
final class ExportHTMLOfflineTests: XCTestCase {
    func testOfflineReopenRendersEmbeddedResourcesWithoutNetwork() async throws {
        let directory = try makeDirectory()
        let imageURL = directory.appendingPathComponent("photo.png")
        try ExportRasterFixture.encoded(.png).write(to: imageURL)
        let source = """
        # Offline Export

        ![pixel](photo.png)

        ![remote](https://example.com/remote.png)

        $E=mc^2$

        ```swift
        let value = 1
        ```

        ```mermaid
        graph TD
        A-->B
        ```
        """
        let controller = try makeController()
        defer { controller.invalidate() }
        controller.exportTimeoutNanoseconds = 30_000_000_000
        let renderID = try await render(
            controller,
            DocumentTextChange(
                text: source,
                version: 1,
                fileKind: .markdown,
                fileURL: directory.appendingPathComponent("post.md")
            )
        )

        let result = await controller.exportHTML(matchingRenderID: renderID)
        guard case let .ready(html, _, _) = result else {
            return XCTFail("Expected ready HTML, got \(result)")
        }

        assertSelfContained(html, directory: directory)
        XCTAssertNil(controller.pendingHTMLExport)
        try await reopen(html)
    }

    /// The `\<url(` bypass: escaping `<` after the URL scan once produced `\\3c url(`,
    /// which WebKit tokenizes as an ident followed by a live url(). A real CSS tokenizer
    /// (the reopened WebView's CSSOM and computed styles) must see no remote URL.
    func testEscapedLessThanURLSinksStayNeutralInTheReopenedDocument() async throws {
        let controller = try makeController()
        defer { controller.invalidate() }
        controller.exportTimeoutNanoseconds = 30_000_000_000
        let renderID = try await render(
            controller,
            DocumentTextChange(text: "# CSS sinks\n\nText", version: 1, fileKind: .markdown, fileURL: nil)
        )
        _ = try await PreviewHostedTestWait.javascript(Self.injectEscapedLessThanSinks, in: controller.webView)

        let result = await controller.exportHTML(matchingRenderID: renderID)
        guard case let .ready(html, _, _) = result else {
            return XCTFail("Expected ready HTML, got \(result)")
        }
        XCTAssertFalse(html.contains("evil.example"))

        let (webView, handler) = try await load(html)
        defer {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
        }
        let found = try await PreviewHostedTestWait.javascript(Self.remoteCSSURLScan, in: webView) as? [String]
        XCTAssertEqual(found, [])
        _ = try await PreviewHostedTestWait.javascript("""
        (() => {
          const control = document.createElement("style");
          control.textContent = "li { list-style-image: url(https://control.invalid/x.png); }";
          document.head.append(control);
          return null;
        })()
        """, in: webView)
        let control = try await PreviewHostedTestWait.javascript(Self.remoteCSSURLScan, in: webView) as? [String]
        XCTAssertTrue(control?.contains { $0.contains("control.invalid") } == true, "The scan must see real url()")
        XCTAssertEqual(handler.requests, ["plainsong-offline://document"])
    }

    private static let injectEscapedLessThanSinks = #"""
    (() => {
      const css = String.raw`li{list-style:\<url(https://evil.example/a.png)}
    .v{--a:\<url(https://evil.example/b.png);background-image:var(--a)}`;
      const head = document.createElement("style");
      head.textContent = css;
      document.head.append(head);
      const wrapper = document.createElement("div");
      wrapper.className = "mermaid-rendered";
      const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
      const style = document.createElementNS("http://www.w3.org/2000/svg", "style");
      style.textContent = css;
      svg.append(style);
      wrapper.append(svg);
      const list = document.createElement("ul");
      list.className = "v";
      list.setAttribute("style", String.raw`list-style:\<url(https://evil.example/c.png);` +
        String.raw`--a:\<url(https://evil.example/d.png);background-image:var(--a)`);
      list.innerHTML = "<li>item</li>";
      document.getElementById("preview-root").append(wrapper, list);
      return null;
    })()
    """#

    private static let remoteCSSURLScan = #"""
    (() => {
      const found = [];
      const pattern = /(^|[^\w\\<\-\u0080-\uffff])url\(\s*["']?([^"')\s]*)/giu;
      const visit = (text, where) => {
        for (const match of text.matchAll(pattern)) {
          const value = match[2];
          if (value && !value.startsWith("#") && !value.startsWith("data:")) found.push(`${where}: ${value}`);
        }
      };
      const rules = (list) => Array.from(list).flatMap((rule) => (
        rule.cssRules ? [rule, ...rules(rule.cssRules)] : [rule]
      ));
      for (const sheet of Array.from(document.styleSheets)) {
        for (const rule of rules(sheet.cssRules)) visit(rule.cssText, "rule");
      }
      for (const element of Array.from(document.querySelectorAll("[style]"))) {
        visit(element.getAttribute("style"), "attribute");
        visit(element.style.cssText, "declared");
      }
      for (const element of Array.from(document.querySelectorAll("ul, li"))) {
        const computed = getComputedStyle(element);
        for (const property of ["list-style-image", "background-image", "--a"]) {
          visit(computed.getPropertyValue(property), `computed ${property}`);
        }
      }
      return found;
    })()
    """#

    private func assertSelfContained(_ html: String, directory: URL) {
        XCTAssertTrue(html.contains("data:image/png;base64,"))
        XCTAssertTrue(html.contains("data:font/woff2;base64,"))
        XCTAssertTrue(html.contains("katex"))
        XCTAssertTrue(html.contains("hljs"))
        XCTAssertTrue(html.contains("mermaid"))
        XCTAssertTrue(html.contains("Content-Security-Policy"))
        XCTAssertFalse(html.contains("asset://"))
        XCTAssertFalse(html.contains("file:"))
        XCTAssertFalse(html.contains(directory.path))
        XCTAssertFalse(html.contains("example.com"))
        XCTAssertFalse(html.contains("url(http"))
        XCTAssertFalse(html.contains("src=\"http"))
        XCTAssertTrue(html.contains("data-theme=\"light\"") || html.contains("data-theme=\"dark\""))
    }

    private func reopen(_ html: String) async throws {
        let (webView, handler) = try await load(html)
        defer {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
        }
        var rendered: [String: Any]?
        let script = """
        (() => {
          const images = Array.from(document.images);
          return {
            width: images[0] ? images[0].naturalWidth : 0,
            katex: Boolean(document.querySelector(".katex")),
            code: Boolean(document.querySelector(".hljs")),
            mermaid: Boolean(document.querySelector(".mermaid-rendered svg"))
          };
        })()
        """
        try await PreviewHostedTestWait.until("offline embedded image decoded") {
            rendered = try await PreviewHostedTestWait.javascript(script, in: webView) as? [String: Any]
            return (rendered?["width"] as? Int ?? 0) > 0
        }

        XCTAssertEqual(handler.requests, ["plainsong-offline://document"])
        XCTAssertGreaterThan(rendered?["width"] as? Int ?? 0, 0)
        XCTAssertEqual(rendered?["katex"] as? Bool, true)
        XCTAssertEqual(rendered?["code"] as? Bool, true)
        XCTAssertEqual(rendered?["mermaid"] as? Bool, true)
    }

    private func load(_ html: String) async throws -> (WKWebView, OfflineDocumentSchemeHandler) {
        let handler = OfflineDocumentSchemeHandler(html: html)
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: "plainsong-offline")
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        addTeardownBlock { @MainActor [weak webView] in
            webView?.stopLoading()
            webView?.navigationDelegate = nil
            webView?.uiDelegate = nil
        }
        var loaded = false
        defer {
            if !loaded {
                webView.stopLoading()
                webView.navigationDelegate = nil
                webView.uiDelegate = nil
            }
        }
        let navigation = NavigationWaiter()
        webView.navigationDelegate = navigation
        try webView.load(URLRequest(url: XCTUnwrap(URL(string: "plainsong-offline://document"))))
        try await PreviewHostedTestWait.until("offline document navigation", timeoutNanoseconds: 10_000_000_000) {
            navigation.didFinish || navigation.failure != nil
        }
        if let failure = navigation.failure {
            throw NSError(domain: "PlainsongOfflineNavigation", code: 1, userInfo: [NSLocalizedDescriptionKey: failure])
        }
        // Keep the original assertions; a timeout/failure throws before any JS is evaluated.
        XCTAssertTrue(navigation.didFinish)
        XCTAssertNil(navigation.failure)
        loaded = true
        return (webView, handler)
    }

    private func makeController() throws -> PreviewController {
        let controller = try PreviewController(previewIndexURL: PreviewBundleFixture.indexURL())
        addTeardownBlock { @MainActor [weak controller] in controller?.invalidate() }
        return controller
    }

    private func render(_ controller: PreviewController, _ change: DocumentTextChange) async throws -> Int {
        try await PreviewHostedTestWait.until("offline preview bridge ready") {
            controller.isReady
        }
        XCTAssertTrue(controller.isReady)
        let renderID = controller.renderForTesting(change)
        try await PreviewHostedTestWait.until(
            "offline render \(renderID) completed",
            timeoutNanoseconds: 30_000_000_000
        ) {
            controller.scrollDeliveryState.completedRenderID == renderID
        }
        XCTAssertEqual(controller.scrollDeliveryState.completedRenderID, renderID)
        return renderID
    }

    private func makeDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("plainsong-offline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }
}

private final class OfflineDocumentSchemeHandler: NSObject, WKURLSchemeHandler {
    private let html: String
    private let lock = NSLock()
    private var requested: [String] = []

    init(html: String) {
        self.html = html
    }

    var requests: [String] {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    func webView(_: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let absolute = urlSchemeTask.request.url?.absoluteString ?? ""
        lock.lock()
        requested.append(absolute)
        lock.unlock()
        guard let url = urlSchemeTask.request.url, url.host == "document" else {
            urlSchemeTask.didFailWithError(URLError(.resourceUnavailable))
            return
        }
        let data = Data(html.utf8)
        let response = URLResponse(
            url: url,
            mimeType: "text/html",
            expectedContentLength: data.count,
            textEncodingName: "utf-8"
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_: WKWebView, stop _: WKURLSchemeTask) {}
}

private final class NavigationWaiter: NSObject, WKNavigationDelegate {
    var didFinish = false
    var failure: String?

    func webView(_: WKWebView, didFinish _: WKNavigation!) {
        didFinish = true
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        failure = error.localizedDescription
    }

    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        failure = error.localizedDescription
    }
}
