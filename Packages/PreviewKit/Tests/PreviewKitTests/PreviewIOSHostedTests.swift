import Foundation
import MarkdownCore
@testable import PreviewKit
import XCTest

@MainActor
final class PreviewIOSHostedTests: XCTestCase {
    func testHostedPageBecomesReadyAndRendersTheLatestDocument() async throws {
        let indexURL = try writeBridgePage()
        defer { try? FileManager.default.removeItem(at: indexURL.deletingLastPathComponent()) }
        let controller = PreviewController(previewIndexURL: indexURL)
        defer { controller.shutdownForTesting() }
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
            let text = try await PreviewHostedTestWait.javascript(
                "document.body.innerText",
                in: controller.webView
            ) as? String
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
        // Return an explicit value after posting so this test observes
        // completion independently from the checkbox event.
        _ = try await PreviewHostedTestWait.javascript(
            """
            window.webkit.messageHandlers.bridge.postMessage({
              name: "checkboxToggled",
              payload: { renderID: \(renderID), line: 1, checked: true, version: 3 }
            });
            "posted"
            """,
            in: controller.webView
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
    }

    func testBundledKitchenSinkAndMDXStayVisible() async throws {
        let indexURL = try bundledPreviewIndex()
        #if os(iOS)
            // Use the same packaged-resource lookup as production, in the real app host.
            let controller = PreviewController()
        #else
            let controller = PreviewController(previewIndexURL: indexURL)
        #endif
        defer { controller.shutdownForTesting() }
        controller.installAssetReader(DirectPreviewAssetReader())
        try await waitUntil("bundle ready") { controller.isReady }
        XCTAssertEqual(
            controller.webView.url?.resolvingSymlinksInPath(),
            indexURL.resolvingSymlinksInPath(),
            "The first controller must load the verified real preview bundle"
        )

        let markdown = try String(contentsOf: fixture("kitchen-sink.md"), encoding: .utf8)
        controller.render(DocumentTextChange(text: markdown, version: 1, fileKind: .markdown, fileURL: nil))
        try await waitUntil("kitchen sink") {
            let text = try await PreviewHostedTestWait.javascript(
                "document.body.innerText",
                in: controller.webView
            ) as? String
            return text?.contains("Kitchen Sink Fixture") == true && text?.contains("Third Level") == true
        }

        try await waitUntil("tables, code, math, and Mermaid") {
            try await PreviewHostedTestWait.javascript(
                """
                document.querySelectorAll('table').length > 0 &&
                document.querySelectorAll('pre code.hljs').length > 0 &&
                document.querySelectorAll('.katex').length > 0 &&
                document.querySelectorAll('.mermaid-rendered svg').length >= 2 &&
                document.querySelectorAll('.mermaid-error').length === 0
                """,
                in: controller.webView
            ) as? Bool == true
        }

        let mdx = try String(contentsOf: fixture("kitchen-sink.mdx"), encoding: .utf8)
        controller.render(DocumentTextChange(text: mdx, version: 0, fileKind: .mdx, fileURL: nil))
        try await waitUntil("mdx placeholder") {
            let text = try await PreviewHostedTestWait.javascript(
                "document.body.innerText",
                in: controller.webView
            ) as? String
            return text?.contains("MDX Kitchen Sink Fixture") == true
                && text?.contains("Third Level") != true
        }

        let hasPlaceholders = try await PreviewHostedTestWait.javascript(
            "document.querySelectorAll('.mdx-component-card').length > 0 && " +
                "document.querySelectorAll('.mdx-expression-chip').length > 0",
            in: controller.webView
        ) as? Bool
        XCTAssertEqual(hasPlaceholders, true)

        let broken = try String(contentsOf: fixture("mdx-syntax-error.mdx"), encoding: .utf8)
        controller.render(DocumentTextChange(text: broken, version: 2, fileKind: .mdx, fileURL: nil))
        try await waitUntil("mdx error banner") {
            try await PreviewHostedTestWait.javascript(
                "document.querySelector('.mdx-error-banner') !== null",
                in: controller.webView
            ) as? Bool == true
        }
        try await waitUntil("mdx error keeps the previous document") {
            let text = try await PreviewHostedTestWait.javascript(
                "document.body.innerText",
                in: controller.webView
            ) as? String
            return text?.contains("MDX Kitchen Sink Fixture") == true
        }
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
        let sourceRoot = repositoryRoot()
            .appendingPathComponent("App/Resources/preview", isDirectory: true)
            .resolvingSymlinksInPath()
        #if os(iOS)
            let indexURL = try XCTUnwrap(
                PreviewController.defaultPreviewIndexURL(),
                "Run make ios-preview in the app-hosted IOSPreview scheme; the host must bundle preview resources"
            )
            let destination = indexURL.deletingLastPathComponent()
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(
                at: sourceRoot,
                includingPropertiesForKeys: [.isRegularFileKey]
            ))
            var fileCount = 0
            for case let file as URL in enumerator {
                guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                // Foundation can enumerate /tmp through its /private/tmp alias.
                // Compare canonical components before deriving the fixture-relative path.
                let rootComponents = sourceRoot.pathComponents
                let fileComponents = file.resolvingSymlinksInPath().pathComponents
                guard fileComponents.starts(with: rootComponents),
                      fileComponents.count > rootComponents.count
                else {
                    throw CocoaError(.fileReadInvalidFileName)
                }
                let relative = fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
                let copied = destination.appendingPathComponent(relative)
                let expectedBytes = try Data(contentsOf: file)
                let copiedBytes = try Data(contentsOf: copied)
                XCTAssertEqual(copiedBytes, expectedBytes, relative)
                fileCount += 1
            }
            XCTAssertGreaterThan(fileCount, 3, "Real preview resources must be present before WebKit loads")
            return indexURL
        #else
            let indexURL = sourceRoot.appendingPathComponent("index.html")
            XCTAssertTrue(FileManager.default.fileExists(atPath: indexURL.path))
            return indexURL
        #endif
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
        try await PreviewHostedTestWait.until(
            description,
            timeoutNanoseconds: timeoutNanoseconds,
            condition: condition
        )
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
