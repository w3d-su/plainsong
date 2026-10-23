@testable import EditorKit
@testable import Plainsong
import XCTest

@MainActor
final class EditorPreviewScrollCoordinatorTests: XCTestCase {
    func testNavigationBypassesPreviewOwnerWithoutAllowingEditorEchoToUndoIt() {
        let coordinator = EditorPreviewScrollCoordinator()
        let document = EditorDocumentIdentity(rawValue: "file:///post.md")
        var deliveredLines: [Int] = []
        var deliveredDocumentIdentifiers: [String?] = []
        var now: UInt64 = 1_000_000_000
        coordinator.installClockForTesting { now }
        coordinator.installPreviewScrollDeliveryOverrideForTesting { line, _, documentIdentifier, completion in
            deliveredLines.append(line)
            deliveredDocumentIdentifiers.append(documentIdentifier)
            completion(true)
        }

        coordinator.previewScrolled(to: 1)
        XCTAssertEqual(coordinator.scrollOwner, .preview)
        now += 90_000_000
        coordinator.editorProxy.onScrollIntent?(
            .navigation(line: 42, documentIdentity: document)
        )

        // Past the first claim's 100 ms window: only the navigation's re-arm keeps it.
        now += 20_000_000
        XCTAssertEqual(coordinator.scrollOwner, .preview, "Navigation must re-arm preview ownership")
        XCTAssertEqual(deliveredLines, [42])
        XCTAssertEqual(deliveredDocumentIdentifiers, [document.rawValue])
        XCTAssertEqual(
            coordinator.previewScrollDeliveryReceipt,
            PreviewScrollDeliveryReceipt(
                requestID: 1,
                line: 42,
                documentIdentifier: document.rawValue,
                ownerAtDispatch: .preview,
                succeeded: true
            )
        )

        coordinator.editorProxy.onScrollIntent?(.viewportChanged(line: 1))
        XCTAssertEqual(deliveredLines, [42], "Preview-driven editor echo must stay suppressed")
        now += 80_000_000
        XCTAssertEqual(coordinator.scrollOwner, .none)
    }

    func testViewportTrafficClaimsEditorOwnershipWithoutReceiptsAndDecays() {
        let coordinator = EditorPreviewScrollCoordinator()
        var now: UInt64 = 5_000_000_000
        var deliveries: [(line: Int, documentIdentifier: String?)] = []
        coordinator.installClockForTesting { now }
        coordinator.installPreviewScrollDeliveryOverrideForTesting { line, _, documentIdentifier, _ in
            deliveries.append((line, documentIdentifier))
        }
        coordinator.setEditorScrollForwardingEnabled(true)

        coordinator.editorProxy.onScrollIntent?(.viewportChanged(line: 10))
        coordinator.editorProxy.onScrollIntent?(.viewportChanged(line: 11))
        XCTAssertEqual(deliveries.map(\.line), [10, 11])
        XCTAssertEqual(deliveries.map(\.documentIdentifier), [nil, nil])
        XCTAssertNil(coordinator.previewScrollDeliveryReceipt, "Viewport traffic leaves no receipt")
        XCTAssertEqual(coordinator.scrollOwner, .editor)

        coordinator.previewScrolled(to: 3)
        XCTAssertEqual(coordinator.scrollOwner, .editor, "The editor owns scrolling for 100 ms")

        now += EditorPreviewScrollCoordinator.ownerDecayNanoseconds - 1
        XCTAssertEqual(coordinator.scrollOwner, .editor)
        now += 1
        XCTAssertEqual(coordinator.scrollOwner, .none)
        coordinator.previewScrolled(to: 3)
        XCTAssertEqual(coordinator.scrollOwner, .preview)
    }

    func testFailedPreviewDeliveryProducesObservableReceipt() {
        let coordinator = EditorPreviewScrollCoordinator()
        let document = EditorDocumentIdentity(rawValue: "file:///post.md")
        coordinator.installPreviewScrollDeliveryOverrideForTesting { _, _, _, completion in
            completion(false)
        }

        coordinator.editorProxy.onScrollIntent?(
            .navigation(line: 42, documentIdentity: document)
        )

        XCTAssertEqual(
            coordinator.previewScrollDeliveryReceipt,
            PreviewScrollDeliveryReceipt(
                requestID: 1,
                line: 42,
                documentIdentifier: document.rawValue,
                ownerAtDispatch: .none,
                succeeded: false
            )
        )
    }

    func testMissingPreviewControllerProducesImmediateFailureReceipt() {
        let coordinator = EditorPreviewScrollCoordinator()
        let document = EditorDocumentIdentity(rawValue: "file:///post.md")

        coordinator.editorProxy.onScrollIntent?(
            .navigation(line: 42, documentIdentity: document)
        )

        XCTAssertEqual(
            coordinator.previewScrollDeliveryReceipt,
            PreviewScrollDeliveryReceipt(
                requestID: 1,
                line: 42,
                documentIdentifier: document.rawValue,
                ownerAtDispatch: .none,
                succeeded: false
            )
        )
    }
}
