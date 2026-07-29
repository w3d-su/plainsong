import AppKit
import MarkdownCore
@testable import PreviewKit
import WebKit
import XCTest

extension ExportPDFMechanismSpikeTests {
    static let multiViewportFirstSentinel = "E0MULTIVIEWPORTFIRSTSENTINEL"
    static let multiViewportLastSentinel = "E0MULTIVIEWPORTLASTSENTINEL"

    static var multiViewportMarkdown: String {
        let body = (0 ..< 90).map { index in
            """
            ## Multi-viewport block \(index)

            Deterministic E0 paragraph \(index) keeps the final sentinel several export
            viewports below the first sentinel for the required negative control.
            """
        }.joined(separator: "\n\n")
        return """
        # \(multiViewportFirstSentinel)

        \(body)

        # \(multiViewportLastSentinel)
        """
    }

    static var tallFixture: E0TallFixture {
        let sentinels = (0 ..< 420).map { String(format: "E0TALLSENTINEL%04d", $0) }
        let markdown = sentinels.enumerated().map { index, sentinel in
            """
            ### \(sentinel) — Tall E0 block \(index) has deterministic wrapped content so its \
            laid-out height is measured rather than inferred from source byte count.
            """
        }.joined(separator: "\n\n")
        return E0TallFixture(markdown: markdown, sentinels: sentinels)
    }

    static func fixtureText(name: String, extension fileExtension: String) throws -> String {
        let bundle = Bundle(for: ExportPDFMechanismSpikeTests.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: name, withExtension: fileExtension),
            "Missing named E0 fixture \(name).\(fileExtension)"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func assertSentinelsInOrder(first: String, last: String, in text: String) throws {
        let firstRange = try XCTUnwrap(text.range(of: first), "Missing first sentinel \(first)")
        let lastRange = try XCTUnwrap(text.range(of: last), "Missing last sentinel \(last)")
        XCTAssertLessThan(firstRange.lowerBound, lastRange.lowerBound)
    }

    static func assertEverySentinelAppearsOnceInOrder(_ sentinels: [String], in text: String) throws {
        var previousOffset = -1
        for sentinel in sentinels {
            XCTAssertEqual(
                text.components(separatedBy: sentinel).count - 1,
                1,
                "\(sentinel) must appear exactly once across the fixed-height page sequence."
            )
            let range = try XCTUnwrap(text.range(of: sentinel), "Missing paginated sentinel \(sentinel)")
            let offset = text.distance(from: text.startIndex, to: range.lowerBound)
            XCTAssertGreaterThan(offset, previousOffset, "\(sentinel) is out of order.")
            previousOffset = offset
        }
    }

    static func observeTallCapture(
        probe: E0OffscreenPDFProbe,
        geometry: E0SettledGeometry,
        firstSentinel: String,
        lastSentinel: String
    ) async -> E0TallObservation {
        do {
            let snapshot = try await probe.capturePDF(rect: geometry.contentBounds)
            let firstRange = snapshot.extractedText.range(of: firstSentinel)
            let lastRange = snapshot.extractedText.range(of: lastSentinel)
            let firstPresent = firstRange != nil
            let lastPresent = lastRange != nil
            let sentinelsInOrder = firstRange.map(\.lowerBound) < lastRange.map(\.lowerBound)

            if snapshot.pageClaims.count > 1 {
                let leadingPagesReachBound = snapshot.pageClaims.dropLast().allSatisfy {
                    $0.hasValidDefaultUserSpace
                        && abs($0.mediaBox.height - 14400) <= 1
                        && abs($0.userUnit - 1) <= 0.001
                }
                let lastPageIsBounded = snapshot.pageClaims.last.map {
                    $0.hasValidDefaultUserSpace
                        && $0.mediaBox.height <= 14400.5
                        && abs($0.userUnit - 1) <= 0.001
                } == true
                let claimedHeight = snapshot.pageClaims.map(\.claimedHeight).reduce(0, +)
                let claimsFullHeight = abs(claimedHeight - geometry.contentBounds.height) <= 4
                let matches: [E0TallCaptureOutcome] =
                    leadingPagesReachBound
                        && lastPageIsBounded
                        && claimsFullHeight
                        && sentinelsInOrder
                        ? [.clipping]
                        : []
                let claims = snapshot.pageClaims.enumerated().map { index, claim in
                    "page\(index)=\(claim.mediaBox),userUnit=\(claim.userUnit)"
                }.joined(separator: ";")
                return E0TallObservation(
                    matchedOutcomes: matches,
                    firstSentinelPresent: firstPresent,
                    lastSentinelPresent: lastPresent,
                    details: "boundClippedPageCount=\(snapshot.pageClaims.count) "
                        + "claimedHeight=\(claimedHeight) first=\(firstPresent) "
                        + "last=\(lastPresent) \(claims)",
                    capturedText: snapshot.extractedText,
                    pageClaims: snapshot.pageClaims
                )
            }

            guard snapshot.pageClaims.count == 1, let claim = snapshot.pageClaims.first else {
                let claims = snapshot.pageClaims.enumerated().map { index, claim in
                    "page\(index)=\(claim.mediaBox),userUnit=\(claim.userUnit)"
                }.joined(separator: ";")
                return E0TallObservation(
                    matchedOutcomes: [],
                    firstSentinelPresent: snapshot.extractedText.contains(firstSentinel),
                    lastSentinelPresent: snapshot.extractedText.contains(lastSentinel),
                    details: "unexpectedPageCount=\(snapshot.pageClaims.count) "
                        + "first=\(firstPresent) last=\(lastPresent) \(claims)"
                )
            }

            let claimsFullHeight = abs(claim.claimedHeight - geometry.contentBounds.height) <= 4
            let usesDefaultUnit = abs(claim.userUnit - 1) <= 0.001
            var matches: [E0TallCaptureOutcome] = []

            if claim.hasValidDefaultUserSpace, claimsFullHeight, sentinelsInOrder {
                matches.append(.continuous)
            }
            if claim.hasValidDefaultUserSpace,
               usesDefaultUnit,
               claim.claimedHeight < geometry.contentBounds.height - 4,
               sentinelsInOrder
            {
                matches.append(.scaling)
            }
            if claim.hasValidDefaultUserSpace,
               usesDefaultUnit,
               abs(claim.mediaBox.height - 14400) <= 256,
               firstPresent,
               !lastPresent
            {
                matches.append(.clipping)
            }
            if !claim.hasValidDefaultUserSpace, claimsFullHeight, sentinelsInOrder {
                matches.append(.invalidPageBox)
            }

            return E0TallObservation(
                matchedOutcomes: matches,
                firstSentinelPresent: firstPresent,
                lastSentinelPresent: lastPresent,
                details: "bytes=\(snapshot.data.count) mediaBox=\(claim.mediaBox) "
                    + "userUnit=\(claim.userUnit) claimedHeight=\(claim.claimedHeight) "
                    + "first=\(firstPresent) last=\(lastPresent)",
                capturedText: snapshot.extractedText,
                pageClaims: snapshot.pageClaims
            )
        } catch let error as E0ProbeError {
            return E0TallObservation(
                matchedOutcomes: [],
                firstSentinelPresent: false,
                lastSentinelPresent: false,
                details: "producedPDFValidationError=\(error)"
            )
        } catch {
            return E0TallObservation(
                matchedOutcomes: [.apiError],
                firstSentinelPresent: false,
                lastSentinelPresent: false,
                details: "apiError=\(error)"
            )
        }
    }

    static func makeVisiblePreviewWindow(webView: WKWebView) -> E0VisiblePreviewWindow {
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let contentView = NSView(frame: window.contentLayoutRect)
        webView.frame = contentView.bounds
        webView.autoresizingMask = [.width, .height]
        contentView.addSubview(webView)

        let firstResponder = E0AcceptingFirstResponderView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        contentView.addSubview(firstResponder)
        window.contentView = contentView
        window.orderFront(nil)
        return E0VisiblePreviewWindow(window: window, firstResponder: firstResponder)
    }

    static func exerciseMDXFailure(
        baselineProcessIDs: Set<pid_t>
    ) async throws -> E0ReleaseEvidence {
        var probe: E0OffscreenPDFProbe? = E0OffscreenPDFProbe()
        let controller = try XCTUnwrap(probe?.controller)
        let controllerBox = E0WeakBox(controller)
        let webViewBox = E0WeakBox(controller.webView)

        _ = try await probe?.render(
            text: "# E0_FAILURE_LAST_GOOD_SENTINEL",
            fileKind: .markdown,
            version: 91
        )
        let failedRender = try await probe?.render(
            text: "import {",
            fileKind: .mdx,
            version: 92
        )
        XCTAssertEqual(failedRender?.completion.renderID, failedRender?.submittedRenderID)
        let failedDOM = try await probe?.domState()
        XCTAssertEqual(failedDOM?.stale, true)
        XCTAssertTrue(failedDOM?.text.contains("E0_FAILURE_LAST_GOOD_SENTINEL") == true)

        var output: Data?
        do {
            try await probe?.requireSuccessfulCurrentDOM()
            let geometry = try await probe?.settleFullContentGeometry()
            if let bounds = geometry?.contentBounds {
                output = try await probe?.capturePDF(rect: bounds).data
            }
            XCTFail("A renderComplete from the MDX-error branch must not authorize capture.")
        } catch E0ProbeError.currentRenderFailed {
            // Required failure: renderComplete alone is not a successful-capture barrier.
        }
        XCTAssertNil(output)
        XCTAssertNil(probe?.controller.webView.window)
        let processIDs = E0WebContentProcessProbe.processIDs().subtracting(baselineProcessIDs)
        probe = nil
        return E0ReleaseEvidence(controller: controllerBox, webView: webViewBox, processIDs: processIDs)
    }

    static func exerciseTimeout() async -> E0ReleaseEvidence {
        var probe: E0OffscreenPDFProbe? = E0OffscreenPDFProbe(previewIndexURL: nil)
        let controllerBox = E0WeakBox(probe?.controller)
        let webViewBox = E0WeakBox(probe?.controller.webView)
        let output: Data? = nil
        do {
            try await probe?.waitUntilReady(timeoutNanoseconds: 100_000_000)
            XCTFail("The bridge-less fixture should time out.")
        } catch E0ProbeError.timeout {
            // Required bounded timeout.
        } catch {
            XCTFail("Unexpected timeout-path error: \(error)")
        }
        XCTAssertNil(output)
        XCTAssertNil(probe?.controller.webView.window)
        probe = nil
        return E0ReleaseEvidence(controller: controllerBox, webView: webViewBox, processIDs: [])
    }

    static func exerciseCancellation() async -> E0ReleaseEvidence {
        var probe: E0OffscreenPDFProbe? = E0OffscreenPDFProbe(previewIndexURL: nil)
        let controllerBox = E0WeakBox(probe?.controller)
        let webViewBox = E0WeakBox(probe?.controller.webView)
        let operationProbe = probe
        let task = Task<Data?, Error> {
            try await operationProbe?.waitUntilReady(timeoutNanoseconds: 5_000_000_000)
            return nil
        }
        task.cancel()

        var output: Data?
        do {
            output = try await task.value
            XCTFail("The cancelled operation must not reach a result.")
        } catch is CancellationError {
            // Required cancellation.
        } catch {
            XCTFail("Unexpected cancellation-path error: \(error)")
        }
        XCTAssertNil(output)
        XCTAssertNil(probe?.controller.webView.window)
        probe = nil
        return E0ReleaseEvidence(controller: controllerBox, webView: webViewBox, processIDs: [])
    }

    static func assertReleased(
        _ box: E0WeakBox<some AnyObject>,
        label: String
    ) async throws {
        try await waitUntil(label, timeoutNanoseconds: 5_000_000_000) {
            box.value == nil
        }
    }

    static func waitUntil(
        _ description: String,
        timeoutNanoseconds: UInt64,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
            try Task.checkCancellation()
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw E0ProbeError.timeout(description)
    }
}

struct E0TallFixture {
    let markdown: String
    let sentinels: [String]
}

enum E0TallCaptureOutcome: String {
    case continuous
    case clipping
    case scaling
    case apiError
    case invalidPageBox
}

struct E0TallObservation {
    let matchedOutcomes: [E0TallCaptureOutcome]
    let firstSentinelPresent: Bool
    let lastSentinelPresent: Bool
    let details: String
    let capturedText: String?
    let pageClaims: [E0PDFPageClaim]

    init(
        matchedOutcomes: [E0TallCaptureOutcome],
        firstSentinelPresent: Bool,
        lastSentinelPresent: Bool,
        details: String,
        capturedText: String? = nil,
        pageClaims: [E0PDFPageClaim] = []
    ) {
        self.matchedOutcomes = matchedOutcomes
        self.firstSentinelPresent = firstSentinelPresent
        self.lastSentinelPresent = lastSentinelPresent
        self.details = details
        self.capturedText = capturedText
        self.pageClaims = pageClaims
    }
}

struct E0VisiblePreviewWindow {
    let window: NSWindow
    let firstResponder: E0AcceptingFirstResponderView
}

final class E0AcceptingFirstResponderView: NSView {
    override var acceptsFirstResponder: Bool {
        true
    }
}

struct E0ReleaseEvidence {
    let controller: E0WeakBox<PreviewController>
    let webView: E0WeakBox<WKWebView>
    let processIDs: Set<pid_t>
}

final class E0WeakBox<T: AnyObject> {
    weak var value: T?

    init(_ value: T?) {
        self.value = value
    }
}

private func < <T: Comparable>(lhs: T?, rhs: T?) -> Bool {
    guard let lhs, let rhs else {
        return false
    }
    return lhs < rhs
}
