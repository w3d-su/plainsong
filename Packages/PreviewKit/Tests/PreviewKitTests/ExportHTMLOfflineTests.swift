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
        controller.exportTimeoutNanoseconds = 30_000_000_000
        let renderID = try await render(
            controller,
            DocumentTextChange(text: "# CSS sinks\n\nText", version: 1, fileKind: .markdown, fileURL: nil)
        )
        _ = try await controller.webView.evaluateJavaScript(Self.injectEscapedLessThanSinks)

        let result = await controller.exportHTML(matchingRenderID: renderID)
        guard case let .ready(html, _, _) = result else {
            return XCTFail("Expected ready HTML, got \(result)")
        }
        XCTAssertFalse(html.contains("evil.example"))

        let (webView, handler) = try await load(html)
        let found = try await webView.evaluateJavaScript(Self.remoteCSSURLScan) as? [String]
        XCTAssertEqual(found, [])
        _ = try await webView.evaluateJavaScript("""
        (() => {
          const control = document.createElement("style");
          control.textContent = "li { list-style-image: url(https://control.invalid/x.png); }";
          document.head.append(control);
          return null;
        })()
        """)
        let control = try await webView.evaluateJavaScript(Self.remoteCSSURLScan) as? [String]
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
        let decodeStart = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - decodeStart < 5_000_000_000 {
            rendered = try await webView.evaluateJavaScript(script) as? [String: Any]
            if (rendered?["width"] as? Int ?? 0) > 0 {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
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
        let navigation = NavigationWaiter()
        webView.navigationDelegate = navigation
        navigation.onFinish = { navigation.didFinish = true }
        try webView.load(URLRequest(url: XCTUnwrap(URL(string: "plainsong-offline://document"))))
        let navigationStart = DispatchTime.now().uptimeNanoseconds
        while !navigation.didFinish,
              DispatchTime.now().uptimeNanoseconds - navigationStart < 10_000_000_000
        {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(navigation.didFinish)
        XCTAssertNil(navigation.failure)
        return (webView, handler)
    }

    private func makeController() throws -> PreviewController {
        let testFile = URL(fileURLWithPath: #filePath)
        let repositoryRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let indexURL = repositoryRoot.appendingPathComponent("App/Resources/preview/index.html")
        let controller = PreviewController(previewIndexURL: indexURL)
        addTeardownBlock { @MainActor [weak controller] in controller?.invalidate() }
        return controller
    }

    private func render(_ controller: PreviewController, _ change: DocumentTextChange) async throws -> Int {
        let start = DispatchTime.now().uptimeNanoseconds
        while !controller.isReady, DispatchTime.now().uptimeNanoseconds - start < 5_000_000_000 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(controller.isReady)
        let renderID = controller.renderForTesting(change)
        let renderStart = DispatchTime.now().uptimeNanoseconds
        while controller.scrollDeliveryState.completedRenderID != renderID,
              DispatchTime.now().uptimeNanoseconds - renderStart < 30_000_000_000
        {
            try await Task.sleep(nanoseconds: 50_000_000)
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
    var onFinish: (() -> Void)?
    var didFinish = false
    var failure: String?

    func webView(_: WKWebView, didFinish _: WKNavigation!) {
        onFinish?()
        onFinish = nil
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        failure = error.localizedDescription
        onFinish?()
        onFinish = nil
    }

    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        failure = error.localizedDescription
        onFinish?()
        onFinish = nil
    }
}
