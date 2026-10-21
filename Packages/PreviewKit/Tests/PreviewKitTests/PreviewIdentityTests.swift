import Foundation
import MarkdownCore
@testable import PreviewKit
import XCTest

@MainActor
final class PreviewIdentityTests: XCTestCase {
    func testLowerVersionDocumentDropsThePreviousCheckbox() {
        let controller = PreviewController(previewIndexURL: nil)
        let first = DocumentSession(text: "first")
        let second = DocumentSession(text: "second")
        var callbacks: [ObjectIdentifier] = []
        controller.onCheckboxToggled = { _, _, _, session in
            callbacks.append(ObjectIdentifier(session))
        }

        controller.render(
            DocumentTextChange(text: "first", version: 9, fileKind: .markdown, fileURL: nil),
            for: first
        )
        let firstRenderID = controller.previewProvenanceForTesting.renderID
        controller.render(
            DocumentTextChange(text: "second", version: 0, fileKind: .markdown, fileURL: nil),
            for: second
        )
        let secondRenderID = controller.previewProvenanceForTesting.renderID
        XCTAssertGreaterThan(secondRenderID ?? -1, firstRenderID ?? 0)

        controller.receive(.checkboxToggled(CheckboxToggledPayload(
            renderID: firstRenderID ?? -1, line: 1, checked: true, version: 9
        )))
        controller.receive(.checkboxToggled(CheckboxToggledPayload(
            renderID: secondRenderID ?? -1, line: 1, checked: true, version: 9
        )))
        XCTAssertTrue(callbacks.isEmpty)
        XCTAssertEqual(first.text, "first")
        XCTAssertEqual(second.text, "second")

        controller.receive(.checkboxToggled(CheckboxToggledPayload(
            renderID: secondRenderID ?? -1, line: 1, checked: true, version: 0
        )))
        XCTAssertEqual(callbacks, [ObjectIdentifier(second)])
        XCTAssertEqual(first.text, "first")
        XCTAssertEqual(second.text, "second")
    }

    func testIOSCheckboxUsesDocumentIdentityAndIgnoresStaleRender() {
        let controller = PreviewController(previewIndexURL: nil)
        let first = IOSDocumentIdentity(rawValue: UUID())
        let second = IOSDocumentIdentity(rawValue: UUID())
        var events: [IOSPreviewEvent] = []
        _ = controller.observe { events.append($0) }

        controller.render(snapshot("First", version: 9), identity: first, assetAccess: nil)
        let firstRenderID = controller.previewProvenanceForTesting.renderID
        controller.render(snapshot("Second", version: 0), identity: second, assetAccess: directoryAccess())
        let secondRenderID = controller.previewProvenanceForTesting.renderID

        controller.receive(.checkboxToggled(CheckboxToggledPayload(
            renderID: firstRenderID ?? -1, line: 2, checked: true, version: 9
        )))
        controller.receive(.checkboxToggled(CheckboxToggledPayload(
            renderID: secondRenderID ?? -1, line: 2, checked: false, version: 0
        )))

        let checkboxes = events.compactMap { event -> (UUID, Int, Int)? in
            guard case let .checkboxRequested(revision, renderID, line, _) = event else { return nil }
            return (revision.documentID.rawValue, renderID, line)
        }
        XCTAssertEqual(checkboxes.count, 1)
        XCTAssertEqual(checkboxes.first?.0, second.rawValue)
        XCTAssertEqual(checkboxes.first?.1, secondRenderID ?? -1)
        XCTAssertEqual(checkboxes.first?.2, 2)
        XCTAssertEqual(controller.previewProvenanceForTesting.identity, second)
    }

    func testCancelledObservationReceivesNoLaterEvents() {
        let controller = PreviewController(previewIndexURL: nil)
        var events: [IOSPreviewEvent] = []
        let token = controller.observe { events.append($0) }
        token.cancel()
        controller.receive(.ready(ReadyPayload(protocolVersion: PreviewBridge.protocolVersion)))
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(controller.isReady)
    }

    func testSingleFileGrantReportsMissingDirectoryAccessAndDoesNotReadSiblings() async {
        let controller = PreviewController(previewIndexURL: nil)
        let reader = GatePreviewAssetReader()
        controller.installAssetReader(reader)
        var events: [IOSPreviewEvent] = []
        _ = controller.observe { events.append($0) }
        let file = URL(fileURLWithPath: "/tmp/site/content/post.md")
        controller.render(
            DocumentSnapshot(
                text: "![Sibling](../images/pixel.png)",
                version: 1,
                fileKind: .markdown,
                fileURL: file,
                isDirty: false,
                statistics: TextStatistics(text: "![Sibling](../images/pixel.png)")
            ),
            identity: IOSDocumentIdentity(rawValue: UUID()),
            assetAccess: nil
        )
        XCTAssertTrue(events.contains { event in
            if case .failed(.unavailable) = event {
                return true
            }
            return false
        })

        let task = RecordingSchemeTask(
            url: PreviewAssetTestSupport.assetURL(token: controller.assetSchemeHandler.currentPlainsongRootToken())
        )
        controller.assetSchemeHandler.start(task)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(reader.readCount, 0)
        XCTAssertEqual(task.failures, 1)
        XCTAssertTrue(task.data.isEmpty)
    }

    func testWebContentTerminationDoesNotMutateSource() {
        let session = DocumentSession(text: "kept")
        let controller = PreviewController(previewIndexURL: nil)
        controller.render(session.currentTextChange, for: session)
        controller.webViewWebContentProcessDidTerminate(controller.webView)
        XCTAssertFalse(controller.isReady)
        XCTAssertEqual(session.text, "kept")
        XCTAssertEqual(session.version, 0)
    }

    func testHostReattachKeepsTheSameWebView() {
        let controller = PreviewController(previewIndexURL: nil)
        let host = PreviewWebHostView(webView: controller.webView)
        let webView = controller.webView
        host.attach(webView: webView)
        XCTAssertTrue(webView.superview === host)
        host.attach(webView: webView)
        XCTAssertTrue(controller.webView === webView)
        XCTAssertTrue(webView.superview === host)
    }

    private func snapshot(_ text: String, version: Int) -> DocumentSnapshot {
        DocumentSnapshot(
            text: text,
            version: version,
            fileKind: .markdown,
            fileURL: nil,
            isDirty: false,
            statistics: TextStatistics(text: text)
        )
    }

    private func directoryAccess() -> PreviewAssetAccessContext {
        PreviewAssetTestSupport.access(
            root: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            generation: 2
        )
    }
}
