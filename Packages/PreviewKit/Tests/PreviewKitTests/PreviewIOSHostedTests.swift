import Foundation
import MarkdownCore
@testable import PreviewKit
import XCTest

@MainActor
final class PreviewIOSHostedTests: XCTestCase {
    func testHostedPageBecomesReadyAndRendersTheLatestDocument() async throws {
        let indexURL = try writeBridgePage()
        let controller = PreviewController(previewIndexURL: indexURL)
        var events: [IOSPreviewEvent] = []
        _ = controller.observe { events.append($0) }
        try await waitUntil("bridge ready") { controller.isReady }
        XCTAssertTrue(events.contains {
            if case .ready = $0 {
                return true
            }; return false
        })

        let identity = IOSDocumentIdentity(rawValue: UUID())
        controller.render(
            DocumentSnapshot(
                text: "Hosted preview line",
                version: 3,
                fileKind: .markdown,
                fileURL: nil,
                isDirty: false,
                statistics: TextStatistics(text: "Hosted preview line")
            ),
            identity: identity,
            assetAccess: nil
        )
        try await waitUntil("hosted text") {
            let text = try await controller.webView.evaluateJavaScript("document.body.innerText") as? String
            return text?.contains("Hosted preview line") == true
        }
        try await waitUntil("render event") {
            events.contains { event in
                if case let .renderCompleted(documentID, _, version) = event {
                    return documentID == identity && version == 3
                }
                return false
            }
        }
        let renderID = try XCTUnwrap(controller.previewProvenanceForTesting.renderID)
        // A script that returns undefined makes this WebKit async API throw
        // InvalidTransition. Return a value after posting the checkbox.
        _ = try await controller.webView.evaluateJavaScript(
            """
            window.webkit.messageHandlers.bridge.postMessage({
              name: "checkboxToggled",
              payload: { renderID: \(renderID), line: 1, checked: true, version: 3 }
            });
            "posted"
            """
        )
        try await waitUntil("checkbox event") {
            events.contains { event in
                if case let .checkboxRequested(revision, eventRenderID, line, checked) = event {
                    return revision.documentID == identity && revision.version == 3
                        && eventRenderID == renderID && line == 1 && checked
                }
                return false
            }
        }
        controller.shutdownForTesting()
    }

    func testBundledKitchenSinkAndMDXStayVisible() async throws {
        #if os(iOS)
            throw XCTSkip(
                """
                The iOS simulator WKWebView does not become ready for loadFileURL of the \
                Mac repository preview bundle. Mac swift test runs this fixture. \
                testHostedPageBecomesReadyAndRendersTheLatestDocument covers the iOS lifecycle.
                """
            )
        #endif
        let indexURL = try bundledPreviewIndex()
        let controller = PreviewController(previewIndexURL: indexURL)
        controller.installAssetReader(DirectPreviewAssetReader())
        try await waitUntil("bundle ready") { controller.isReady }

        let markdown = try String(contentsOf: fixture("kitchen-sink.md"), encoding: .utf8)
        controller.render(DocumentTextChange(text: markdown, version: 1, fileKind: .markdown, fileURL: nil))
        try await waitUntil("kitchen sink") {
            let text = try await controller.webView.evaluateJavaScript("document.body.innerText") as? String
            return text?.contains("Kitchen Sink Fixture") == true && text?.contains("Third Level") == true
        }

        let mdx = try String(contentsOf: fixture("kitchen-sink.mdx"), encoding: .utf8)
        controller.render(DocumentTextChange(text: mdx, version: 0, fileKind: .mdx, fileURL: nil))
        try await waitUntil("mdx placeholder") {
            let text = try await controller.webView.evaluateJavaScript("document.body.innerText") as? String
            return text?.contains("MDX Kitchen Sink Fixture") == true
                && text?.contains("Third Level") != true
        }

        let broken = try String(contentsOf: fixture("mdx-syntax-error.mdx"), encoding: .utf8)
        controller.render(DocumentTextChange(text: broken, version: 2, fileKind: .mdx, fileURL: nil))
        try await waitUntil("mdx error keeps the previous document") {
            let text = try await controller.webView.evaluateJavaScript("document.body.innerText") as? String
            return text?.contains("MDX Kitchen Sink Fixture") == true
        }
        controller.shutdownForTesting()
    }

    private func writeBridgePage() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let indexURL = directory.appendingPathComponent("index.html")
        try Data(Self.bridgeHTML.utf8).write(to: indexURL)
        return indexURL
    }

    private func bundledPreviewIndex() throws -> URL {
        let indexURL = repositoryRoot().appendingPathComponent("App/Resources/preview/index.html")
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexURL.path))
        return indexURL
    }

    private func fixture(_ name: String) throws -> URL {
        let url = repositoryRoot().appendingPathComponent("Fixtures/\(name)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        return url
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func waitUntil(
        _ description: String,
        timeoutNanoseconds: UInt64 = 8_000_000_000,
        condition: @escaping @MainActor () async throws -> Bool
    ) async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
            if try await condition() {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for \(description)")
    }

    private static let bridgeHTML = """
    <!doctype html><meta charset="utf-8"><body></body>
    <script>
    window.PlainsongPreview = { PROTOCOL_VERSION: 8 };
    window.PlainsongBridge = {
      receive(message) {
        if (message.name === "render") {
          document.body.innerText = message.payload.text;
          window.webkit.messageHandlers.bridge.postMessage({
            name: "renderComplete",
            payload: { renderID: message.payload.renderID, version: message.payload.version, blockCount: 1 }
          });
        }
      }
    };
    </script>
    """
}
