import AppKit
import MarkdownCore
import Network
import PDFKit
@testable import Plainsong
@testable import PreviewKit
import WebKit
import XCTest

@MainActor
final class ExportPDFOfflineTests: XCTestCase {
    func testPDFCaptureIssuesZeroHTTPRequestsWithLiveRemotePreferenceOn() async throws {
        let support = ExportHTMLCommandAppTests()
        let fixture = try support.makeFixture(text: """
        # PDF offline

        ![HTTP](http://plainsong-app-export.invalid/a.png)

        ![HTTPS](https://plainsong-app-export.invalid/b.png)

        $E=mc^2$
        """)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let proxy = try ExportHTTPProxyClient()
        let port = try XCTUnwrap(NWEndpoint.Port(rawValue: proxy.port))
        try await assertNoRequests(proxy)
        let proxies = [ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: port))]
        fixture.appState.preferences.setAllowsRemoteImages(true)
        let destination = fixture.exportsDirectory.appendingPathComponent("offline.pdf")
        func proxyDataStore() -> WKWebsiteDataStore {
            let store = WKWebsiteDataStore.nonPersistent()
            store.proxyConfigurations = proxies
            return store
        }
        fixture.appState.exportHTMLOperations.websiteDataStoreProvider = proxyDataStore
        fixture.appState.exportHTMLOperations.destinationChooser = { _ in destination }
        try await XCTUnwrap(fixture.appState.exportCurrentDocumentAsPDF()).value
        try await assertNoRequests(proxy)
        fixture.appState.exportHTMLOperations.destinationChooser = { _ in
            XCTFail("Print must not open a save panel")
            return nil
        }
        fixture.appState.exportHTMLOperations.printOperationRunner = { _, _ in true }
        try await XCTUnwrap(fixture.appState.printCurrentDocument()).value
        try await assertNoRequests(proxy)
        XCTAssertTrue(fixture.appState.preferences.allowsRemoteImages)
        let data = try Data(contentsOf: destination)
        XCTAssertTrue(data.starts(with: Data("%PDF".utf8)))
        let text = (0 ..< (PDFDocument(data: data)?.pageCount ?? 0)).compactMap {
            PDFDocument(data: data)?.page(at: $0)?.string
        }.joined()
        XCTAssertTrue(text.contains("PDF offline"))
        let live = PreviewController(
            previewIndexURL: PreviewController.defaultPreviewIndexURL(),
            websiteDataStore: proxyDataStore()
        )
        defer { live.invalidate() }
        live.setAllowsRemoteImages(true)
        _ = await live.renderForExport(DocumentTextChange(
            text: "![control](https://plainsong-app-export.invalid/control.png)", version: 1,
            fileKind: .markdown, fileURL: fixture.session.fileURL
        ))
        let deadline = Date().addingTimeInterval(10)
        var requests = try await proxy.requests()
        while requests.isEmpty, Date() < deadline {
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
