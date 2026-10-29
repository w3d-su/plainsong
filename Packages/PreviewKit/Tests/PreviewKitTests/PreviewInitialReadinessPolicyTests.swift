import Foundation
import MarkdownCore
@testable import PreviewKit
import WebKit
import XCTest

@MainActor
final class PreviewInitialReadinessPolicyTests: XCTestCase {
    override func setUp() async throws {
        // Load counts below are taken inside init, which loads synchronously only
        // after the shared content rules are already compiled.
        _ = await PreviewRemoteImageRuleStore.rules()
    }

    func testDefaultInitialRetryPolicyIsLimitedToIOS() {
        let clock = InitialReadinessTestClock()
        let page = InitialReadinessTestPage()
        let controller = PreviewController(
            previewIndexURL: nil,
            initialReadinessScheduler: clock.schedule,
            pageLoadOverrideForTesting: page.load
        )
        defer { controller.invalidate() }

        #if os(iOS)
            XCTAssertTrue(controller.retriesSilentInitialLoad)
            XCTAssertEqual(clock.deadlines.count, 1)
        #else
            XCTAssertFalse(controller.retriesSilentInitialLoad)
            XCTAssertTrue(clock.deadlines.isEmpty)
        #endif
        XCTAssertEqual(page.loads.count, 1)
    }

    func testDisabledInitialRetryNeverArmsAndStillFlushesNormalReady() {
        let clock = InitialReadinessTestClock()
        let page = InitialReadinessTestPage()
        let controller = PreviewController(
            previewIndexURL: nil,
            retriesSilentInitialLoad: false,
            initialReadinessScheduler: clock.schedule,
            pageLoadOverrideForTesting: page.load
        )
        controller.bridgeTransportOverrideForTesting = page.send
        defer { controller.invalidate() }
        let renderID = controller.renderForTesting(InitialReadinessTestFixture.change("kept source"))

        controller.startInitialReadinessWatchdog()
        XCTAssertTrue(clock.deadlines.isEmpty)
        XCTAssertTrue(page.renderedPayloads.isEmpty)
        controller.receive(InitialReadinessTestFixture.ready)

        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(page.loads.count, 1)
        XCTAssertEqual(page.renderedPayloads.map(\.renderID), [renderID])
    }

    func testNilNavigationRetryUsesCurrentPageProbeBeforeFlushingQueuedRender() {
        let fixture = InitialReadinessTestFixture()
        let controller = fixture.controller
        defer { controller.invalidate() }
        let renderID = controller.renderForTesting(InitialReadinessTestFixture.change("exact queued source"))
        fixture.clock.fire()
        XCTAssertNil(controller.currentPageNavigation)

        controller.receive(.ready(ReadyPayload(protocolVersion: PreviewBridge.protocolVersion + 1)))
        XCTAssertTrue(fixture.page.readinessReplies.isEmpty)
        controller.receive(InitialReadinessTestFixture.ready)
        XCTAssertEqual(fixture.page.readinessReplies.count, 1)
        XCTAssertFalse(controller.isReady)
        XCTAssertTrue(fixture.page.renderedPayloads.isEmpty)
        fixture.page.readinessReplies[0](PreviewBridge.protocolVersion + 1)
        XCTAssertFalse(controller.isReady)

        controller.receive(InitialReadinessTestFixture.ready)
        XCTAssertEqual(fixture.page.readinessReplies.count, 2)
        fixture.page.readinessReplies[1](PreviewBridge.protocolVersion)

        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(fixture.page.loads.count, 2)
        XCTAssertEqual(fixture.page.renderedPayloads.map(\.renderID), [renderID])
        XCTAssertEqual(fixture.page.renderedPayloads.first?.text, "exact queued source")
        fixture.clock.fire()
        XCTAssertEqual(fixture.page.loads.count, 2)
    }

    func testRetriedNavigationRequiresItsOwnWebViewAndNavigationBeforeProbing() throws {
        let fixture = InitialReadinessTestFixture()
        let navigationSource = WKWebView(frame: .zero)
        let otherSource = WKWebView(frame: .zero)
        let controller = fixture.controller
        defer {
            controller.invalidate()
            navigationSource.stopLoading()
            otherSource.stopLoading()
        }
        fixture.clock.fire()
        // Use handles returned by WebKit. Directly constructed tokens trapped
        // during deallocation in this fixture.
        let navigation = try XCTUnwrap(navigationSource.loadHTMLString("<p>current</p>", baseURL: nil))
        let unrelatedNavigation = try XCTUnwrap(otherSource.loadHTMLString("<p>other</p>", baseURL: nil))
        XCTAssertFalse(navigation === unrelatedNavigation)
        controller.currentPageNavigation = navigation

        controller.receive(InitialReadinessTestFixture.ready)
        controller.webView(controller.webView, didFinish: unrelatedNavigation)
        controller.webView(otherSource, didFinish: navigation)
        XCTAssertTrue(fixture.page.readinessReplies.isEmpty)
        XCTAssertFalse(controller.isReady)

        controller.webView(controller.webView, didFinish: navigation)
        XCTAssertEqual(fixture.page.readinessReplies.count, 1)
        fixture.page.readinessReplies[0](PreviewBridge.protocolVersion)
        XCTAssertTrue(controller.isReady)
    }

    func testNilNavigationReadyFallbackRejectsSupersededAndInvalidatedProbeReplies() {
        let fixture = InitialReadinessTestFixture()
        let controller = fixture.controller
        defer { controller.invalidate() }
        fixture.clock.fire()
        controller.receive(InitialReadinessTestFixture.ready)
        XCTAssertEqual(fixture.page.readinessReplies.count, 1)
        let oldGeneration = controller.pageLoadGeneration

        controller.loadPreviewPage()
        XCTAssertNotEqual(controller.pageLoadGeneration, oldGeneration)
        fixture.page.readinessReplies[0](PreviewBridge.protocolVersion)
        XCTAssertFalse(controller.isReady)
        controller.receive(InitialReadinessTestFixture.ready)
        XCTAssertEqual(fixture.page.readinessReplies.count, 2)

        controller.invalidate()
        fixture.page.readinessReplies[1](PreviewBridge.protocolVersion)
        XCTAssertFalse(controller.isReady)
        XCTAssertTrue(fixture.page.renderedPayloads.isEmpty)
    }
}
