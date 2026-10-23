import Foundation
import MarkdownCore
@testable import PreviewKit
import XCTest

/// Single-flight render dispatch (`docs/decisions/2026-10-22-preview-render-single-flight.md`),
/// driven through the bridge transport seam so no WebKit page is involved.
@MainActor
final class PreviewRenderDispatchTests: XCTestCase {
    func testOneRenderIsInFlightAndTheNewestReplacesThePending() {
        let harness = RenderDispatchHarness(testCase: self)
        harness.markReady()

        let first = harness.controller.renderForTesting(change("one", version: 1))
        let second = harness.controller.renderForTesting(change("two", version: 2))
        let third = harness.controller.renderForTesting(change("three", version: 3))
        XCTAssertEqual(harness.sentRenderIDs, [first], "Later renders wait for the in-flight one")
        XCTAssertEqual(harness.controller.renderDispatch.pending?.renderID, third)

        harness.complete(first)
        XCTAssertEqual(harness.sentRenderIDs, [first, third], "The replaced render is never sent")
        XCTAssertFalse(harness.sentRenderIDs.contains(second))
        XCTAssertEqual(harness.sentTexts, ["one", "three"])

        harness.complete(third)
        XCTAssertNil(harness.controller.renderDispatch.inFlightRenderID)
        XCTAssertEqual(harness.controller.scrollDeliveryState.completedRenderID, third)
    }

    func testRendersBeforeReadySendOnlyTheNewestOnReady() {
        let harness = RenderDispatchHarness(testCase: self)
        _ = harness.controller.renderForTesting(change("early", version: 1))
        let newest = harness.controller.renderForTesting(change("newest", version: 2))
        XCTAssertTrue(harness.sentRenderIDs.isEmpty)

        harness.markReady()
        XCTAssertEqual(harness.sentRenderIDs, [newest])
        harness.markReady()
        XCTAssertEqual(harness.sentRenderIDs, [newest], "A repeated ready must not resend the in-flight render")
    }

    func testPendingRenderReadsTheThemeWhenItIsSent() {
        let harness = RenderDispatchHarness(testCase: self)
        harness.markReady()
        let first = harness.controller.renderForTesting(change("one", version: 1))
        _ = harness.controller.renderForTesting(change("two", version: 2))
        harness.controller.setTheme("dark")
        harness.controller.setAllowsRemoteImages(true)

        harness.complete(first)
        XCTAssertEqual(harness.sentRenders.last?.theme, "dark")
        XCTAssertEqual(harness.sentRenders.last?.allowRemoteImages, true)
    }

    func testUnchangedPreviewSettingsSendNothing() {
        let harness = RenderDispatchHarness(testCase: self)
        harness.markReady()
        let settingsAfterReady = harness.settingsMessageCount
        harness.controller.setTheme("system")
        harness.controller.setAllowsRemoteImages(false)
        XCTAssertEqual(harness.settingsMessageCount, settingsAfterReady)
        harness.controller.setTheme("dark")
        XCTAssertEqual(harness.settingsMessageCount, settingsAfterReady + 1)
    }

    func testWatchdogReleasesARenderJavaScriptNeverAnswers() async throws {
        let harness = RenderDispatchHarness(testCase: self)
        harness.markReady()
        harness.controller.renderWatchdogNanoseconds = 50_000_000
        let stalled = harness.controller.renderForTesting(change("throws", version: 1))
        harness.controller.renderWatchdogNanoseconds = 60_000_000_000
        let next = harness.controller.renderForTesting(change("next", version: 2))
        XCTAssertEqual(harness.sentRenderIDs, [stalled])

        try await waitUntil("watchdog sends the pending render") { harness.sentRenderIDs == [stalled, next] }

        // A late answer from the stalled render must not free the newer render's slot.
        let afterNext = harness.controller.renderForTesting(change("after", version: 3))
        harness.complete(stalled)
        XCTAssertEqual(harness.sentRenderIDs, [stalled, next])
        harness.complete(next)
        XCTAssertEqual(harness.sentRenderIDs, [stalled, next, afterNext])
    }

    func testFailedDeliveryFreesTheSlotAndDoesNotSuppressTheSameRender() {
        let harness = RenderDispatchHarness(testCase: self)
        harness.markReady()
        let session = DocumentSession(text: "kept")
        harness.deliverySucceeds = false
        harness.controller.render(session.currentTextChange, for: session)
        XCTAssertEqual(harness.sentRenderIDs.count, 1)
        XCTAssertNil(harness.controller.renderDispatch.inFlightRenderID)

        harness.deliverySucceeds = true
        harness.controller.render(session.currentTextChange, for: session)
        XCTAssertEqual(harness.sentRenderIDs.count, 2, "JavaScript never saw the failed render")
    }

    func testIdenticalSessionPresentationIsSubmittedOnce() {
        let harness = RenderDispatchHarness(testCase: self)
        harness.markReady()
        let session = DocumentSession(text: "# Post")
        harness.controller.setPresentedDocumentIdentifier("post")

        harness.controller.render(session.currentTextChange, for: session)
        harness.controller.render(session.currentTextChange, for: session)
        XCTAssertEqual(harness.sentRenderIDs.count, 1, "Pane show plus observe(_:) must not render twice")

        harness.complete(harness.sentRenderIDs[0])
        harness.controller.render(session.currentTextChange, for: session)
        XCTAssertEqual(harness.sentRenderIDs.count, 1)

        session.replaceText("# Post edited")
        harness.controller.render(session.currentTextChange, for: session)
        XCTAssertEqual(harness.sentRenderIDs.count, 2, "A new version renders")
        harness.complete(harness.sentRenderIDs[1])

        harness.controller.setTheme("dark")
        harness.controller.render(session.currentTextChange, for: session)
        XCTAssertEqual(harness.sentRenderIDs.count, 3, "A changed presentation renders")
        harness.complete(harness.sentRenderIDs[2])

        let reopened = DocumentSession(text: "# Post")
        reopened.replaceText("# Post edited")
        XCTAssertEqual(reopened.version, session.version)
        harness.controller.render(reopened.currentTextChange, for: reopened)
        XCTAssertEqual(harness.sentRenderIDs.count, 4, "Another session never matches")
        harness.complete(harness.sentRenderIDs[3])

        _ = harness.controller.renderForTesting(reopened.currentTextChange)
        harness.complete(harness.sentRenderIDs[4])
        harness.controller.render(reopened.currentTextChange, for: reopened)
        XCTAssertEqual(harness.sentRenderIDs.count, 6, "A session-less render clears the record")
    }

    func testWebContentTerminationKeepsTheNewestPendingRenderAndClearsDuplicates() {
        let harness = RenderDispatchHarness(testCase: self)
        harness.markReady()
        let session = DocumentSession(text: "kept")
        harness.controller.render(session.currentTextChange, for: session)
        let pending = harness.controller.renderForTesting(change("pending", version: 4))

        harness.controller.webViewWebContentProcessDidTerminate(harness.controller.webView)
        XCTAssertNil(harness.controller.renderDispatch.inFlightRenderID)
        XCTAssertEqual(harness.controller.renderDispatch.pending?.renderID, pending)
        XCTAssertNil(harness.controller.lastSubmittedRender)

        harness.markReady()
        XCTAssertEqual(harness.sentRenderIDs.last, pending)
    }

    func testInvalidationDropsPendingRenderWork() {
        let harness = RenderDispatchHarness(testCase: self)
        harness.markReady()
        let first = harness.controller.renderForTesting(change("one", version: 1))
        _ = harness.controller.renderForTesting(change("two", version: 2))
        harness.controller.invalidate()
        XCTAssertNil(harness.controller.renderDispatch.pending)
        harness.controller.receive(.renderComplete(RenderCompletePayload(renderID: first, version: 1, blockCount: 0)))
        XCTAssertEqual(harness.sentRenderIDs, [first])
    }

    func testCheckboxProvenanceNamesTheNewestSubmittedRender() {
        let harness = RenderDispatchHarness(testCase: self)
        harness.markReady()
        let session = DocumentSession(text: "- [ ] task")
        var toggles: [Int] = []
        harness.controller.onCheckboxToggled = { line, _, _, _ in toggles.append(line) }

        let inFlight = harness.controller.renderForTesting(change("- [ ] old", version: 7))
        session.replaceText("- [ ] task\n")
        harness.controller.render(session.currentTextChange, for: session)
        let newest = harness.controller.previewProvenanceForTesting.renderID
        XCTAssertEqual(harness.sentRenderIDs, [inFlight])

        harness.controller.receive(.checkboxToggled(CheckboxToggledPayload(
            renderID: inFlight, line: 1, checked: true, version: 7
        )))
        XCTAssertTrue(toggles.isEmpty, "The superseded DOM cannot write back")
        harness.controller.receive(.checkboxToggled(CheckboxToggledPayload(
            renderID: newest ?? -1, line: 1, checked: true, version: session.version
        )))
        XCTAssertEqual(toggles, [1])
    }

    func testRenderMessageBodyIsTheCodableMessage() throws {
        for baseDir in [nil, "content/posts"] as [String?] {
            let payload = RenderPayload(
                renderID: 12,
                version: 3,
                fileKind: .mdx,
                text: "# Title \"quoted\" \\ </script> \u{2028} 🎉",
                baseDir: baseDir,
                theme: "dark",
                allowRemoteImages: true,
                assetRootID: "root-a"
            )
            let encoded = try JSONEncoder().encode(BridgeMessage.render(payload))
            let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? NSDictionary)
            let body = PreviewController.renderMessageBody(payload)
            XCTAssertEqual(body as NSDictionary, expected)
            let fields = try XCTUnwrap(body["payload"] as? [String: Any])
            let flag = try XCTUnwrap(fields["allowRemoteImages"] as? NSNumber)
            XCTAssertEqual(CFGetTypeID(flag), CFBooleanGetTypeID())
        }
    }

    func testAssetContextIsCachedPerFileAndWorkspaceRoot() {
        let controller = PreviewController(previewIndexURL: nil)
        defer { controller.invalidate() }
        let root = URL(fileURLWithPath: "/tmp/site", isDirectory: true)
        let file = URL(fileURLWithPath: "/tmp/site/content/post.md")
        controller.setWorkspaceAssetRoot(root)
        XCTAssertEqual(
            controller.cachedAssetContext(fileURL: file),
            PreviewController.assetContext(fileURL: file, workspaceRootURL: root.standardizedFileURL)
        )
        XCTAssertEqual(controller.assetContextCache?.fileURL, file)

        controller.setWorkspaceAssetRoot(nil)
        XCTAssertEqual(
            controller.cachedAssetContext(fileURL: file),
            PreviewController.assetContext(fileURL: file, workspaceRootURL: nil)
        )
        XCTAssertNil(controller.assetContextCache?.workspaceRootURL)
    }

    private func change(_ text: String, version: Int) -> DocumentTextChange {
        DocumentTextChange(text: text, version: version, fileKind: .markdown, fileURL: nil)
    }

    private func waitUntil(
        _ description: String,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        try await PreviewHostedTestWait.until(description, timeoutNanoseconds: 5_000_000_000) {
            condition()
        }
    }
}

/// A controller whose outgoing bridge messages are recorded instead of evaluated.
@MainActor
final class RenderDispatchHarness {
    let controller: PreviewController
    var deliverySucceeds = true
    private(set) var sentRenders: [RenderPayload] = []
    private(set) var sentScrollLines: [Int] = []
    private(set) var settingsMessageCount = 0
    private(set) var heldScrollCompletions: [@MainActor (Bool) -> Void] = []

    var sentRenderIDs: [Int] {
        sentRenders.map(\.renderID)
    }

    var sentTexts: [String] {
        sentRenders.map(\.text)
    }

    init(testCase: XCTestCase, recoversFromWebContentTermination: Bool = false) {
        controller = PreviewController(
            previewIndexURL: nil,
            recoversFromWebContentTermination: recoversFromWebContentTermination
        )
        controller.bridgeTransportOverrideForTesting = { [unowned self] message, completion in
            switch message {
            case let .render(payload):
                sentRenders.append(payload)
                completion?(deliverySucceeds)
            case let .scrollToLine(payload):
                sentScrollLines.append(payload.line)
                if let completion {
                    heldScrollCompletions.append(completion)
                }
            case .setTheme:
                settingsMessageCount += 1
                completion?(true)
            default:
                completion?(true)
            }
        }
        // Even a nil-index controller owns a real WKWebView. Register cleanup before any await.
        testCase.addTeardownBlock { @MainActor [harness = self] in
            harness.controller.invalidate()
            harness.controller.bridgeTransportOverrideForTesting = nil
            harness.heldScrollCompletions.removeAll()
        }
    }

    func markReady() {
        controller.receive(.ready(ReadyPayload(protocolVersion: PreviewBridge.protocolVersion)))
    }

    func complete(_ renderID: Int) {
        let version = sentRenders.last { $0.renderID == renderID }?.version ?? 0
        controller.receive(.renderComplete(RenderCompletePayload(renderID: renderID, version: version, blockCount: 1)))
    }

    func finishOldestScroll(succeeded: Bool = true) {
        guard !heldScrollCompletions.isEmpty else { return }
        heldScrollCompletions.removeFirst()(succeeded)
    }
}
