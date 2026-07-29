import AppKit
import Darwin
import MarkdownCore
import PDFKit
@testable import Plainsong
@testable import PreviewKit
import WebKit
import XCTest

@MainActor
final class ExportPDFMechanismSpikeTests: XCTestCase {
    func testDedicatedOffscreenControllerRendersNamedMarkdownAndMDXAtExactSubmittedRenderIDs() async throws {
        let probe = E0OffscreenPDFProbe()
        XCTAssertNil(probe.controller.webView.window)

        let markdown = try Self.fixtureText(name: "export-e0-markdown", extension: "md")
        let markdownRender = try await probe.render(text: markdown, fileKind: .markdown, version: 41)
        XCTAssertEqual(markdownRender.completion.renderID, markdownRender.submittedRenderID)
        XCTAssertEqual(markdownRender.completion.version, 41)
        XCTAssertGreaterThan(markdownRender.completion.blockCount, 0)
        let markdownDOM = try await probe.domState()
        XCTAssertTrue(markdownDOM.text.contains("E0MARKDOWNFIRSTSENTINEL"))
        XCTAssertTrue(markdownDOM.text.contains("E0MARKDOWNLASTSENTINEL"))
        XCTAssertFalse(markdownDOM.stale)

        let mdx = try Self.fixtureText(name: "export-e0-mdx", extension: "mdx")
        let mdxRender = try await probe.render(text: mdx, fileKind: .mdx, version: 42)
        XCTAssertEqual(mdxRender.completion.renderID, mdxRender.submittedRenderID)
        XCTAssertEqual(mdxRender.completion.version, 42)
        XCTAssertGreaterThan(mdxRender.completion.blockCount, 0)
        let mdxDOM = try await probe.domState()
        XCTAssertTrue(mdxDOM.text.contains("E0MDXFIRSTSENTINEL"))
        XCTAssertTrue(mdxDOM.text.contains("E0MDXLASTSENTINEL"))
        XCTAssertTrue(mdxDOM.text.contains("ExportCard"))
        XCTAssertFalse(mdxDOM.stale)
    }

    func testExplicitFullContentRectAndNegativeViewportControlProveMultiViewportPDF() async throws {
        let probe = E0OffscreenPDFProbe()
        let render = try await probe.render(
            text: Self.multiViewportMarkdown,
            fileKind: .markdown,
            version: 51
        )
        try await probe.requireSuccessfulCurrentDOM()
        let geometry = try await probe.settleFullContentGeometry()

        XCTAssertEqual(render.completion.renderID, render.submittedRenderID)
        XCTAssertGreaterThan(geometry.exportViewport.width, 0)
        XCTAssertGreaterThan(geometry.exportViewport.height, 0)
        XCTAssertGreaterThan(geometry.contentBounds.height, geometry.exportViewport.height * 3)

        let fullCapture = try await probe.capturePDF(rect: geometry.contentBounds)
        XCTAssertEqual(fullCapture.configurationRect, geometry.contentBounds)
        XCTAssertFalse(fullCapture.data.isEmpty)
        try Self.assertSentinelsInOrder(
            first: Self.multiViewportFirstSentinel,
            last: Self.multiViewportLastSentinel,
            in: fullCapture.extractedText
        )

        let firstViewportRect = CGRect(
            x: geometry.contentBounds.minX,
            y: geometry.contentBounds.minY,
            width: geometry.contentBounds.width,
            height: geometry.exportViewport.height
        )
        let negativeCapture = try await probe.capturePDF(rect: firstViewportRect)
        XCTAssertEqual(negativeCapture.configurationRect, firstViewportRect)
        XCTAssertTrue(negativeCapture.extractedText.contains(Self.multiViewportFirstSentinel))
        XCTAssertFalse(
            negativeCapture.extractedText.contains(Self.multiViewportLastSentinel),
            "The required negative control must not contain the last-block sentinel."
        )
        XCTContext.runActivity(named: String(
            format: "E0 negative control contentHeight=%.1f viewportHeight=%.1f lastSentinel=false",
            geometry.contentBounds.height,
            geometry.exportViewport.height
        )) { _ in }
    }

    func testTallCaptureEnumeratesBoundOutcomeAndPaginatesWithoutDuplicateOrDroppedSentinels() async throws {
        let probe = E0OffscreenPDFProbe()
        let fixture = Self.tallFixture
        let render = try await probe.render(text: fixture.markdown, fileKind: .markdown, version: 61)
        try await probe.requireSuccessfulCurrentDOM()
        let geometry = try await probe.settleFullContentGeometry(timeoutNanoseconds: 10_000_000_000)

        XCTAssertEqual(render.completion.renderID, render.submittedRenderID)
        XCTAssertGreaterThan(
            geometry.contentBounds.height,
            14400,
            "The E0 tall fixture must fail rather than silently exercising a shorter document."
        )

        let observation = try await Self.observeTallCapture(
            probe: probe,
            geometry: geometry,
            firstSentinel: XCTUnwrap(fixture.sentinels.first),
            lastSentinel: XCTUnwrap(fixture.sentinels.last)
        )
        XCTAssertEqual(
            observation.matchedOutcomes.count,
            1,
            "Tall capture must match exactly one enumerated outcome: \(observation.details)"
        )
        let outcome = try XCTUnwrap(observation.matchedOutcomes.first)
        print(
            "E0 TALL height=\(geometry.contentBounds.height) outcome=\(outcome.rawValue) "
                + observation.details
        )
        XCTContext.runActivity(named: String(
            format: "E0 tall measuredHeight=%.1f outcome=%@ %@",
            geometry.contentBounds.height,
            outcome.rawValue,
            observation.details
        )) { _ in }

        if outcome == .continuous {
            XCTAssertTrue(observation.firstSentinelPresent)
            XCTAssertTrue(observation.lastSentinelPresent)
            return
        }

        let pageHeight: CGFloat
        do {
            pageHeight = try await probe.chooseFixedPaginationHeight(contentBounds: geometry.contentBounds)
        } catch {
            XCTFail("Fixed-height planning failed: \(error)")
            return
        }
        let pages: [E0PDFSnapshot]
        do {
            pages = try await probe.captureFixedHeightPages(
                contentBounds: geometry.contentBounds,
                pageHeight: pageHeight
            )
        } catch {
            XCTFail("Fixed-height capture failed at pageHeight \(pageHeight): \(error)")
            return
        }
        XCTAssertGreaterThan(pages.count, 1)
        let paginatedText = pages.map(\.extractedText).joined(separator: "\n\u{0C}\n")
        try Self.assertEverySentinelAppearsOnceInOrder(fixture.sentinels, in: paginatedText)
        XCTAssertTrue(pages.allSatisfy { page in
            page.pageClaims.count == 1
                && page.pageClaims[0].hasValidDefaultUserSpace
                && page.pageClaims[0].mediaBox.height <= pageHeight + 0.5
        })
        print("E0 TALL fallback=GO(paginated) pageHeight=\(pageHeight) pages=\(pages.count)")
        XCTContext.runActivity(named: String(
            format: "E0 fallback GO paginated pageHeight=%.1f pages=%d sentinels=%d",
            pageHeight,
            pages.count,
            fixture.sentinels.count
        )) { _ in }
    }

    func testVisiblePreviewStateAndFirstResponderRemainUnchangedDuringOffscreenCapture() async throws {
        let visibleProbe = E0OffscreenPDFProbe()
        visibleProbe.controller.setTheme("dark")
        let windowFixture = Self.makeVisiblePreviewWindow(webView: visibleProbe.controller.webView)
        defer {
            windowFixture.window.orderOut(nil)
            windowFixture.window.contentView = nil
        }

        XCTAssertTrue(windowFixture.window.isVisible)
        XCTAssertTrue(windowFixture.window.makeFirstResponder(windowFixture.firstResponder))
        let visibleRender = try await visibleProbe.render(
            text: Self.multiViewportMarkdown,
            fileKind: .markdown,
            version: 71
        )
        try await visibleProbe.scroll(toY: 900)
        try await visibleProbe.waitUntil("visible preview scrolled", timeoutNanoseconds: 5_000_000_000) {
            try await visibleProbe.domState().scrollY > 0
        }

        let before = try await visibleProbe.domState()
        let beforeResponder = windowFixture.window.firstResponder
        let beforeCompletedRenderIDs = visibleProbe.completedRenders.keys.sorted()

        let exportProbe = E0OffscreenPDFProbe()
        XCTAssertNil(exportProbe.controller.webView.window)
        _ = try await exportProbe.render(
            text: Self.fixtureText(name: "export-e0-markdown", extension: "md"),
            fileKind: .markdown,
            version: 72
        )
        let exportGeometry = try await exportProbe.settleFullContentGeometry()
        _ = try await exportProbe.capturePDF(rect: exportGeometry.contentBounds)

        let after = try await visibleProbe.domState()
        XCTAssertEqual(visibleRender.completion.renderID, visibleRender.submittedRenderID)
        XCTAssertEqual(after.scrollY, before.scrollY, accuracy: 0.5)
        XCTAssertEqual(after.theme, before.theme)
        XCTAssertEqual(after.html, before.html)
        XCTAssertEqual(after.theme, "dark")
        XCTAssertTrue(windowFixture.window.firstResponder === beforeResponder)
        XCTAssertEqual(visibleProbe.completedRenders.keys.sorted(), beforeCompletedRenderIDs)
    }

    func testSourceOnlyAndExperimentalWYSIWYGExportWithoutMountingVisiblePreview() async throws {
        for layoutMode in [EditorLayoutMode.sourceOnly, .wysiwyg] {
            let suiteName = "ExportPDFMechanismSpikeTests.\(layoutMode.rawValue).\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.removePersistentDomain(forName: suiteName)

            let appState = AppState(userDefaults: defaults)
            if layoutMode == .wysiwyg {
                appState.preferences.setExperimentalWYSIWYGEnabled(true)
            }
            appState.setLayoutMode(layoutMode)
            XCTAssertEqual(appState.layoutMode, layoutMode)
            XCTAssertFalse(appState.isPreviewVisible)

            let probe = E0OffscreenPDFProbe()
            XCTAssertNil(probe.controller.webView.window)
            _ = try await probe.render(
                text: Self.fixtureText(name: "export-e0-markdown", extension: "md"),
                fileKind: .markdown,
                version: layoutMode == .sourceOnly ? 81 : 82
            )
            let geometry = try await probe.settleFullContentGeometry()
            let capture = try await probe.capturePDF(rect: geometry.contentBounds)
            try Self.assertSentinelsInOrder(
                first: "E0MARKDOWNFIRSTSENTINEL",
                last: "E0MARKDOWNLASTSENTINEL",
                in: capture.extractedText
            )
            XCTAssertNil(probe.controller.webView.window)
        }
    }

    func testRenderCompleteAloneIsInsufficientAndFailureTimeoutCancellationReleaseResources() async throws {
        let baselineProcessIDs = E0WebContentProcessProbe.processIDs()
        var observedExportProcessIDs: Set<pid_t> = []

        let failed = try await Self.exerciseMDXFailure(baselineProcessIDs: baselineProcessIDs)
        observedExportProcessIDs.formUnion(failed.processIDs)
        try await Self.assertReleased(failed.controller, label: "failed controller")
        try await Self.assertReleased(failed.webView, label: "failed WebView")

        let timedOut = await Self.exerciseTimeout()
        try await Self.assertReleased(timedOut.controller, label: "timed-out controller")
        try await Self.assertReleased(timedOut.webView, label: "timed-out WebView")

        let cancelled = await Self.exerciseCancellation()
        try await Self.assertReleased(cancelled.controller, label: "cancelled controller")
        try await Self.assertReleased(cancelled.webView, label: "cancelled WebView")

        XCTAssertFalse(
            observedExportProcessIDs.isEmpty,
            "The hosted spike must observe the dedicated WebContent process before proving it is released."
        )
        try await Self.waitUntil("dedicated WebContent process released", timeoutNanoseconds: 10_000_000_000) {
            E0WebContentProcessProbe.processIDs().isDisjoint(with: observedExportProcessIDs)
        }
    }

    func testDiagnosticPDFCallStaysTestOnlyInMemoryWithProtocolV5AndNoDestinationWrite() async throws {
        XCTAssertEqual(PreviewBridge.protocolVersion, 5)
        XCTAssertEqual(
            BridgeMessageName.allCases.map(\.rawValue),
            [
                "ready",
                "render",
                "renderComplete",
                "scrollToLine",
                "previewScrolled",
                "linkClicked",
                "checkboxToggled",
                "setTheme",
            ]
        )

        let probe = E0OffscreenPDFProbe()
        XCTAssertNil(probe.controller.webView.window)
        _ = try await probe.render(
            text: Self.fixtureText(name: "export-e0-markdown", extension: "md"),
            fileKind: .markdown,
            version: 101
        )
        let geometry = try await probe.settleFullContentGeometry()
        let inMemoryPDF = try await probe.capturePDF(rect: geometry.contentBounds)
        XCTAssertFalse(inMemoryPDF.data.isEmpty)
        XCTAssertEqual(
            Mirror(reflecting: probe).children.compactMap(\.label).sorted(),
            ["completedRenders", "controller"]
        )
        XCTAssertNil(probe.controller.webView.window)
    }
}
