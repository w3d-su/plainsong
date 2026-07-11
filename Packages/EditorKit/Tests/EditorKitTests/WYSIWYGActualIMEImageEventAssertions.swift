import AppKit
@testable import EditorKit
import XCTest

@MainActor
extension ActualIMEEventHarness {
    func imageThumbnailConfiguration(
        for scenario: ActualIMEFoldBoundaryScenario
    ) -> EditorImageThumbnailConfiguration? {
        guard let state = scenario.imagePresentationState else {
            return nil
        }
        let delayNanoseconds: UInt64 = switch state {
        case .readyThumbnail:
            0
        case .loadingPlaceholder:
            60_000_000_000
        }
        let loader = TestEditorImageThumbnailLoader(
            outcomes: [
                "fixture.png": WYSIWYGImageThumbnailGateSupport.readyOutcome(
                    source: "fixture.png",
                    resolvedPath: "posts/fixture.png"
                ),
            ],
            delayNanoseconds: delayNanoseconds
        )
        return EditorImageThumbnailConfiguration(
            loader: loader,
            rootURL: URL(fileURLWithPath: "/tmp/PlainsongActualIMEImageGate", isDirectory: true),
            documentDirectoryRelativePath: "posts"
        )
    }

    func assertExpectedImagePresentation(
        in textView: MarkdownSTTextView,
        script: ActualIMEScript,
        scenario: ActualIMEFoldBoundaryScenario,
        phase: String
    ) throws {
        guard let expectedState = scenario.imagePresentationState else {
            return
        }
        let currentText = Self.text(in: textView)
        let imageRange = (currentText as NSString).range(of: actualIMEImageGateLiteral)
        XCTAssertNotEqual(imageRange.location, NSNotFound)

        let marker = try XCTUnwrap(
            waitForImageMarker(in: textView, range: imageRange, expectedState: expectedState),
            "Expected \(expectedState.scenarioName) \(phase) for \(script.name) \(scenario.name)"
        )
        switch expectedState {
        case .readyThumbnail:
            guard case .ready = marker.visualState else {
                XCTFail(
                    "Expected ready thumbnail \(phase) for \(script.name) \(scenario.name)"
                )
                return
            }
        case .loadingPlaceholder:
            XCTAssertEqual(marker.visualState, .loading)
        }

        let projected = try WYSIWYGImageThumbnailGateSupport.projectedImageParagraph(
            in: textView,
            imageRange: imageRange
        ).0.attributedString.string
        XCTAssertEqual(
            projected.unicodeScalars.filter { $0.value == 0xFFFC }.count,
            1,
            "Expected image presentation to be reapplied \(phase) for \(script.name) \(scenario.name)"
        )
    }

    private func waitForImageMarker(
        in textView: MarkdownSTTextView,
        range: NSRange,
        expectedState: ActualIMEImagePresentationState
    ) -> WYSIWYGImagePresentationMarker? {
        let deadline = Date(timeIntervalSinceNow: 2)
        repeat {
            if let marker = WYSIWYGImageThumbnailGateSupport.imageMarker(in: textView, range: range) {
                switch (expectedState, marker.visualState) {
                case (.readyThumbnail, .ready), (.loadingPlaceholder, .loading):
                    return marker
                default:
                    break
                }
            }
            pumpRunLoop(for: 0.01)
        } while Date() < deadline
        return nil
    }
}
