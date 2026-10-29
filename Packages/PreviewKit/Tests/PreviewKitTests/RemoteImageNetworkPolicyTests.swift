#if os(macOS)
    import MarkdownCore
    import Network
    @testable import PreviewKit
    import WebKit
    import XCTest

    /// The content rule, not the `<img>` rewriter, is what keeps a disabled remote-image
    /// switch from contacting the network. Hosts are distinct so the CONNECT proxy shows
    /// which load was attempted; the tunnel is refused and TLS is not completed.
    @MainActor
    final class RemoteImageNetworkPolicyTests: XCTestCase {
        private func imageHosts(for token: String) -> [String] {
            // Inline SVG `<image href>` is an image resource, so the https-image exception allows it.
            ["img", "srcset", "picture", "css", "imageset", "poster", "preload", "inlinesvg"].map {
                "plainsong-\($0)-\(token).invalid"
            }
        }

        private func blockedHosts(for token: String) -> [String] {
            ["svg", "script", "font", "fetch", "style", "http", "import", "iframe", "prefetch", "preconnect"].map {
                "plainsong-\($0)-\(token).invalid"
            }
        }

        func testSwitchingRemoteImagesDoesNotReloadAndOnlyHTTPSImagesConnect() async throws {
            let harness = try await ProxyHarness()
            defer { harness.proxy.stop() }
            let controller = try harness.makeLiveController()
            defer { controller.invalidate() }
            try await PreviewHostedTestWait.until("preview ready") { controller.isReady }
            let generation = controller.pageLoadGeneration
            let page = controller.webView.url
            let marker = try await PreviewHostedTestWait.javascript(
                "window.__marker = 42; window.__marker",
                in: controller.webView
            )
            XCTAssertEqual((marker as? NSNumber)?.intValue, 42)

            let blocked = harness.proxy.connections.count
            try await installWave("off", in: controller.webView)
            try await harness.assertNoNewConnections(since: blocked)

            controller.setAllowsRemoteImages(true)
            XCTAssertTrue(controller.allowRemoteImages)
            XCTAssertEqual(controller.pageLoadGeneration, generation)
            XCTAssertEqual(controller.webView.url, page)
            let enabledMarker = try await PreviewHostedTestWait.javascript("window.__marker", in: controller.webView)
            XCTAssertEqual((enabledMarker as? NSNumber)?.intValue, 42)
            let enabled = harness.proxy.connections.count
            try await installWave("on", in: controller.webView)
            let allowed = try await harness.connections(since: enabled, containingAll: imageHosts(for: "on"))
            assertOnlyImageHosts(allowed, token: "on")

            // The proxy refuses the tunnel, so WebKit retries the allowed images.
            // Detach that wave and let those retries finish before measuring the
            // switched-off page; otherwise a retry looks like a new request.
            try await removeProbeNodes(in: controller.webView)
            try await harness.waitForQuiet()
            controller.setAllowsRemoteImages(false)
            XCTAssertFalse(controller.allowRemoteImages)
            XCTAssertEqual(controller.pageLoadGeneration, generation)
            let restored = try await PreviewHostedTestWait.javascript("window.__marker", in: controller.webView)
            XCTAssertEqual((restored as? NSNumber)?.intValue, 42)
            let disabled = harness.proxy.connections.count
            try await installWave("again", in: controller.webView)
            try await harness.assertNoNewConnections(since: disabled)
        }

        func testImageRuleCompileFailureKeepsTheSwitchOff() async throws {
            let compiled = try await makeRules(
                blockSource: PreviewRemoteImageRuleStore.blockSource,
                imagesSource: "{not-json"
            )
            XCTAssertNotNil(compiled.blockAll)
            XCTAssertNil(compiled.httpsImages)
            let harness = try await ProxyHarness()
            defer { harness.proxy.stop() }
            let controller = try harness.makeLiveController(rules: compiled)
            defer { controller.invalidate() }
            try await PreviewHostedTestWait.until("blocked preview ready") { controller.isReady }
            let baseline = harness.proxy.connections.count
            controller.setAllowsRemoteImages(true)
            XCTAssertFalse(controller.allowRemoteImages)
            try await installWave("failed-images", in: controller.webView)
            try await harness.assertNoNewConnections(since: baseline)
        }

        func testBlockRuleCompileFailureDoesNotLoadOrOpenTheNetwork() async throws {
            let compiled = try await makeRules(
                blockSource: "{not-json",
                imagesSource: PreviewRemoteImageRuleStore.imagesSource
            )
            XCTAssertNil(compiled.blockAll)
            XCTAssertNil(compiled.httpsImages)
            let harness = try await ProxyHarness()
            defer { harness.proxy.stop() }
            let controller = try harness.makeLiveController(rules: compiled)
            defer { controller.invalidate() }
            var events: [IOSPreviewEvent] = []
            _ = controller.observe { events.append($0) }
            XCTAssertTrue(controller.remoteImageNetworkUnavailable)
            XCTAssertTrue(events.contains { if case .contentRuleUnavailable = $0 { return true }; return false })
            controller.setAllowsRemoteImages(true)
            XCTAssertFalse(controller.allowRemoteImages)
            try await Task.sleep(nanoseconds: 400_000_000)
            XCTAssertFalse(controller.isReady)
            XCTAssertNil(controller.webView.url)
            XCTAssertEqual(harness.proxy.connections, [])
        }

        func testRuleIdentifierChangesWhenTheSourceChanges() {
            XCTAssertEqual(
                PreviewRemoteImageRuleStore.blockIdentifier,
                PreviewRemoteImageRuleStore.identifier(
                    prefix: "plainsong-preview-block",
                    source: PreviewRemoteImageRuleStore.blockSource
                )
            )
            XCTAssertNotEqual(
                PreviewRemoteImageRuleStore.blockIdentifier,
                PreviewRemoteImageRuleStore.identifier(
                    prefix: "plainsong-preview-block",
                    source: PreviewRemoteImageRuleStore.blockSource + " "
                )
            )
            XCTAssertTrue(PreviewRemoteImageRuleStore.blockSource.contains("wss?"))
        }

        /// CSP on the file URL does not explain every silent host. Removing the rule must
        /// still contact script, style, and font, or the blocked-wave assertions are empty.
        func testCSPAloneStillContactsRemoteScriptStyleAndFont() async throws {
            let harness = try await ProxyHarness()
            defer { harness.proxy.stop() }
            let controller = try harness.makeLiveController()
            defer { controller.invalidate() }
            try await PreviewHostedTestWait.until("csp control ready") { controller.isReady }
            let rule = try XCTUnwrap(controller.activeContentRuleList)
            controller.webView.configuration.userContentController.remove(rule)
            controller.activeContentRuleList = nil
            try await Task.sleep(nanoseconds: 200_000_000)
            let baseline = harness.proxy.connections.count
            try await installWave("csp", in: controller.webView)
            let contacted = try await harness.connections(
                since: baseline,
                containingAll: ["script", "font", "style", "import"].map { "plainsong-\($0)-csp.invalid" }
            )
            for kind in ["img", "srcset", "picture", "css", "imageset", "script", "font", "style", "import"] {
                let host = "plainsong-\(kind)-csp.invalid"
                XCTAssertTrue(
                    contacted.contains { $0.contains(host) },
                    "CSP alone did not request \(host): \(contacted)"
                )
            }
            for kind in ["fetch", "http"] {
                let host = "plainsong-\(kind)-csp.invalid"
                XCTAssertFalse(contacted.contains { $0.contains(host) }, "CSP should still block \(host): \(contacted)")
            }
        }

        func testExportControllerBlocksInjectedRemoteLoads() async throws {
            let harness = try await ProxyHarness()
            defer { harness.proxy.stop() }
            let controller = try await PreviewController.makeHTMLExportController(
                previewIndexURL: PreviewBundleFixture.indexURL(),
                websiteDataStore: harness.dataStore
            )
            addTeardownBlock { @MainActor [controller] in controller.invalidate() }
            try await PreviewHostedTestWait.until("export preview ready") { controller.isReady }
            let baseline = harness.proxy.connections.count
            try await installWave("export", in: controller.webView)
            try await harness.assertNoNewConnections(since: baseline)
            controller.setAllowsRemoteImages(true)
            XCTAssertFalse(controller.allowRemoteImages)
            let forced = harness.proxy.connections.count
            try await installWave("export-on", in: controller.webView)
            try await harness.assertNoNewConnections(since: forced)
        }

        private func makeRules(blockSource: String, imagesSource: String) async throws -> PreviewRemoteImageRules {
            let compiled = await PreviewRemoteImageRuleStore.makeRules(
                blockSource: blockSource,
                imagesSource: imagesSource
            )
            let identifiers = compiled.identifiers
            addTeardownBlock {
                PreviewRemoteImageRuleStore.removeStoredRules(identifiers: identifiers)
            }
            return compiled.rules
        }

        private func installWave(_ token: String, in webView: WKWebView) async throws {
            let script = """
            (() => {
              const root = document.getElementById("root") || document.body;
              const add = (node) => {
                node.setAttribute("data-plainsong-probe", "1");
                root.appendChild(node);
              };
              const image = document.createElement("img");
              image.src = "https://plainsong-img-\(token).invalid/\(token).png";
              add(image);
              const srcset = document.createElement("img");
              srcset.srcset = "https://plainsong-srcset-\(token).invalid/\(token).png 1x";
              add(srcset);
              const picture = document.createElement("picture");
              const source = document.createElement("source");
              source.srcset = "https://plainsong-picture-\(token).invalid/\(token).png";
              picture.appendChild(source);
              picture.appendChild(document.createElement("img"));
              add(picture);
              const css = document.createElement("div");
              css.style.width = "8px";
              css.style.height = "8px";
              css.style.backgroundImage = "url(https://plainsong-css-\(token).invalid/\(token).png)";
              add(css);
              const svg = document.createElement("img");
              const svgText = '<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8">'
                + '<image href="https://plainsong-svg-\(token).invalid/\(token).png" width="8" height="8"/></svg>';
              svg.src = "data:image/svg+xml," + encodeURIComponent(svgText);
              add(svg);
              const scriptEl = document.createElement("script");
              scriptEl.src = "https://plainsong-script-\(token).invalid/\(token).js";
              scriptEl.setAttribute("data-plainsong-probe", "1");
              document.documentElement.appendChild(scriptEl);
              const style = document.createElement("style");
              style.textContent = "@font-face{font-family:'Probe\(token)';"
                + "src:url(https://plainsong-font-\(token).invalid/\(token).woff2)}";
              style.setAttribute("data-plainsong-probe", "1");
              document.documentElement.appendChild(style);
              const fontUser = document.createElement("span");
              fontUser.style.fontFamily = "'Probe\(token)'";
              fontUser.textContent = "x";
              add(fontUser);
              const imageSet = document.createElement("div");
              imageSet.style.width = "8px";
              imageSet.style.height = "8px";
              imageSet.style.backgroundImage = "image-set(url(https://plainsong-imageset-\(token).invalid/\(
                  token
              ).png) 1x)";
              add(imageSet);
              const imported = document.createElement("style");
              imported.textContent = "@import url(https://plainsong-import-\(token).invalid/\(token).css);";
              imported.setAttribute("data-plainsong-probe", "1");
              document.documentElement.appendChild(imported);
              const video = document.createElement("video");
              video.poster = "https://plainsong-poster-\(token).invalid/\(token).png";
              add(video);
              const frame = document.createElement("iframe");
              frame.src = "https://plainsong-iframe-\(token).invalid/\(token).html";
              add(frame);
              const preload = document.createElement("link");
              preload.rel = "preload";
              preload.as = "image";
              preload.href = "https://plainsong-preload-\(token).invalid/\(token).png";
              preload.setAttribute("data-plainsong-probe", "1");
              document.documentElement.appendChild(preload);
              const prefetch = document.createElement("link");
              prefetch.rel = "prefetch";
              prefetch.href = "https://plainsong-prefetch-\(token).invalid/\(token).txt";
              prefetch.setAttribute("data-plainsong-probe", "1");
              document.documentElement.appendChild(prefetch);
              const preconnect = document.createElement("link");
              preconnect.rel = "preconnect";
              preconnect.href = "https://plainsong-preconnect-\(token).invalid";
              preconnect.setAttribute("data-plainsong-probe", "1");
              document.documentElement.appendChild(preconnect);
              const inline = document.createElementNS("http://www.w3.org/2000/svg", "svg");
              inline.setAttribute("width", "8");
              inline.setAttribute("height", "8");
              const nested = document.createElementNS("http://www.w3.org/2000/svg", "image");
              nested.setAttribute("href", "https://plainsong-inlinesvg-\(token).invalid/\(token).png");
              inline.appendChild(nested);
              add(inline);
              fetch("https://plainsong-fetch-\(token).invalid/\(token).json").catch(() => {});
              const link = document.createElement("link");
              link.rel = "stylesheet";
              link.href = "https://plainsong-style-\(token).invalid/\(token).css";
              link.setAttribute("data-plainsong-probe", "1");
              document.documentElement.appendChild(link);
              const http = document.createElement("img");
              http.src = "http://plainsong-http-\(token).invalid/\(token).png";
              add(http);
              return "ok";
            })()
            """
            _ = try await PreviewHostedTestWait.javascript(script, in: webView)
        }

        private func removeProbeNodes(in webView: WKWebView) async throws {
            let script = """
            (() => {
              document.querySelectorAll("[data-plainsong-probe]").forEach((node) => {
                if (node instanceof HTMLImageElement) node.src = "";
                if (node instanceof HTMLIFrameElement) node.src = "";
                if (node instanceof HTMLVideoElement) node.poster = "";
                if (node instanceof HTMLStyleElement) node.textContent = "";
                if (node instanceof HTMLLinkElement) node.href = "";
                node.remove();
              });
              return "ok";
            })()
            """
            _ = try await PreviewHostedTestWait.javascript(script, in: webView)
        }

        private func assertOnlyImageHosts(_ lines: [String], token: String) {
            for host in imageHosts(for: token) {
                XCTAssertTrue(lines.contains { $0.contains(host) }, "missing \(host) in \(lines)")
            }
            for host in blockedHosts(for: token) {
                XCTAssertFalse(lines.contains { $0.contains(host) }, "unexpected \(host) in \(lines)")
            }
        }
    }

    @MainActor
    private final class ProxyHarness {
        let proxy: LoopbackProxyRecorder
        let dataStore: WKWebsiteDataStore

        init() async throws {
            proxy = try LoopbackProxyRecorder()
            let port = try await proxy.start()
            dataStore = .nonPersistent()
            dataStore.proxyConfigurations = [
                ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: port)),
            ]
        }

        func makeLiveController(rules: PreviewRemoteImageRules? = nil) throws -> PreviewController {
            try PreviewController(
                previewIndexURL: PreviewBundleFixture.indexURL(),
                websiteDataStore: dataStore,
                remoteImageRules: rules
            )
        }

        func connections(since baseline: Int, containingAll hosts: [String]) async throws -> [String] {
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                let added = Array(proxy.connections.dropFirst(baseline))
                if hosts.allSatisfy({ host in added.contains { $0.contains(host) } }) {
                    // Images can arrive before a blocked stylesheet or font. Keep the
                    // snapshot only after the proxy has been quiet.
                    try await Task.sleep(nanoseconds: 500_000_000)
                    return Array(proxy.connections.dropFirst(baseline))
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            return Array(proxy.connections.dropFirst(baseline))
        }

        func waitForQuiet() async throws {
            var seen = proxy.connections.count
            let deadline = Date().addingTimeInterval(4)
            while Date() < deadline {
                try await Task.sleep(nanoseconds: 300_000_000)
                let count = proxy.connections.count
                if count == seen {
                    return
                }
                seen = count
            }
        }

        func assertNoNewConnections(since baseline: Int) async throws {
            let deadline = Date().addingTimeInterval(2.5)
            while Date() < deadline {
                let added = Array(proxy.connections.dropFirst(baseline))
                if !added.isEmpty {
                    XCTFail("unexpected remote requests: \(added)")
                    return
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            XCTAssertEqual(Array(proxy.connections.dropFirst(baseline)), [])
        }
    }
#endif
