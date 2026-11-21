@testable import PreviewKit
import XCTest

@MainActor
final class PreviewEventHubInvalidationTests: XCTestCase {
    private final class Captured {}

    func testInvalidateReleasesObserverHandlers() {
        let controller = PreviewController(previewIndexURL: nil)
        var captured: Captured? = Captured()
        weak var weakCaptured = captured
        let observation = controller.observe { [captured] _ in _ = captured }
        captured = nil
        XCTAssertNotNil(weakCaptured)
        XCTAssertEqual(controller.eventHub.observationCount, 1)

        controller.invalidate()

        XCTAssertNil(weakCaptured)
        XCTAssertEqual(controller.eventHub.observationCount, 0)
        observation.cancel()
    }

    func testObserverAddedAfterInvalidationIsNotRetained() {
        let controller = PreviewController(previewIndexURL: nil)
        controller.invalidate()
        var captured: Captured? = Captured()
        weak var weakCaptured = captured

        let observation = controller.observe { [captured] _ in _ = captured }
        captured = nil

        XCTAssertNil(weakCaptured)
        XCTAssertEqual(controller.eventHub.observationCount, 0)
        observation.cancel()
    }

    func testCancelStillRemovesALiveObservation() {
        let controller = PreviewController(previewIndexURL: nil)
        defer { controller.invalidate() }
        let observation = controller.observe { _ in }

        observation.cancel()

        XCTAssertEqual(controller.eventHub.observationCount, 0)
    }
}
