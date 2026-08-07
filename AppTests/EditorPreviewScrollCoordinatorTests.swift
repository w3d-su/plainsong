@testable import EditorKit
@testable import Plainsong
import XCTest

@MainActor
final class EditorPreviewScrollCoordinatorTests: XCTestCase {
    func testNavigationBypassesPreviewOwnerWithoutAllowingEditorEchoToUndoIt() {
        let coordinator = EditorPreviewScrollCoordinator()
        var deliveredLines: [Int] = []
        var scheduledDecays: [@MainActor () -> Void] = []
        coordinator.installOwnerDecaySchedulerForTesting { completion in
            scheduledDecays.append(completion)
            return Task {}
        }
        coordinator.installPreviewScrollDeliveryOverrideForTesting { line, _, completion in
            deliveredLines.append(line)
            completion(true)
        }

        coordinator.previewScrolled(to: 1)
        XCTAssertEqual(coordinator.scrollOwner, .preview)
        coordinator.editorProxy.onScrollIntent?(.navigation(line: 42))

        XCTAssertEqual(scheduledDecays.count, 2, "Navigation must re-arm preview ownership")
        scheduledDecays[0]()
        XCTAssertEqual(coordinator.scrollOwner, .preview)
        XCTAssertEqual(deliveredLines, [42])
        XCTAssertEqual(
            coordinator.previewScrollDeliveryReceipt,
            PreviewScrollDeliveryReceipt(
                requestID: 1,
                line: 42,
                ownerAtDispatch: .preview,
                succeeded: true
            )
        )

        coordinator.editorProxy.onScrollIntent?(.viewportChanged(line: 1))
        XCTAssertEqual(deliveredLines, [42], "Preview-driven editor echo must stay suppressed")
        scheduledDecays[1]()
        XCTAssertEqual(coordinator.scrollOwner, .none)
    }

    func testFailedPreviewDeliveryProducesObservableReceipt() {
        let coordinator = EditorPreviewScrollCoordinator()
        coordinator.installPreviewScrollDeliveryOverrideForTesting { _, _, completion in
            completion(false)
        }

        coordinator.editorProxy.onScrollIntent?(.navigation(line: 42))

        XCTAssertEqual(
            coordinator.previewScrollDeliveryReceipt,
            PreviewScrollDeliveryReceipt(
                requestID: 1,
                line: 42,
                ownerAtDispatch: .none,
                succeeded: false
            )
        )
    }

    func testMissingPreviewControllerProducesImmediateFailureReceipt() {
        let coordinator = EditorPreviewScrollCoordinator()

        coordinator.editorProxy.onScrollIntent?(.navigation(line: 42))

        XCTAssertEqual(
            coordinator.previewScrollDeliveryReceipt,
            PreviewScrollDeliveryReceipt(
                requestID: 1,
                line: 42,
                ownerAtDispatch: .none,
                succeeded: false
            )
        )
    }
}
