@testable import EditorKit
import MarkdownCore
import XCTest

@MainActor
final class EditorFindControllerLifetimeTests: XCTestCase {
    func testControllerDeallocatesWhileDetachedMatchIsHeldWithoutNotifyingAfterRelease() async throws {
        var controller: EditorFindController? = makeController()
        weak var weakController: EditorFindController?
        weakController = controller
        let hold = EditorFindMatchHold()
        defer { hold.release() }
        controller?.testMatchHold = hold
        let unexpectedNotification = expectation(description: "No session notification after controller release")
        unexpectedNotification.isInverted = true
        var notificationCount = 0
        var didReleaseController = false
        controller?.onSessionDidChange = {
            notificationCount += 1
            if didReleaseController {
                unexpectedNotification.fulfill()
            }
        }

        controller?.setQuery(TextSearchQuery(pattern: "needle"))
        // This proves the detached worker has started and is suspended before searching.
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) { hold.waiterCount == 1 }
        XCTAssertEqual(hold.waiterCount, 1)
        XCTAssertEqual(controller?.completedMatchCount, 0)
        XCTAssertNil(controller?.session)
        XCTAssertEqual(notificationCount, 1, "The observer must see synchronous session invalidation")
        let notificationCountBeforeRelease = notificationCount

        didReleaseController = true
        controller = nil
        XCTAssertNil(weakController, "In-flight work must not retain the controller")
        XCTAssertEqual(hold.waiterCount, 1, "The controller must deallocate before the worker is released")

        // Detached work still completes despite the worker owner's deinit cancelling its task.
        hold.release()
        await fulfillment(of: [unexpectedNotification], timeout: 0.2)
        XCTAssertNil(weakController)
        XCTAssertEqual(notificationCount, notificationCountBeforeRelease)
    }

    func testHeldDetachedMatchNotifiesWhenControllerRemainsAlive() async throws {
        let controller = makeController()
        let hold = EditorFindMatchHold()
        defer { hold.release() }
        controller.testMatchHold = hold
        let completedNotification = expectation(description: "Held match publishes its session after release")
        var notificationCount = 0
        controller.onSessionDidChange = { [weak controller] in
            notificationCount += 1
            if controller?.completedMatchCount == 1 {
                completedNotification.fulfill()
            }
        }

        controller.setQuery(TextSearchQuery(pattern: "needle"))
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) { hold.waiterCount == 1 }
        XCTAssertEqual(hold.waiterCount, 1)
        XCTAssertEqual(controller.completedMatchCount, 0)
        XCTAssertEqual(notificationCount, 1)

        hold.release()
        await fulfillment(of: [completedNotification], timeout: 2)
        XCTAssertEqual(controller.completedMatchCount, 1)
        XCTAssertEqual(controller.session?.total, 1)
        XCTAssertTrue(controller.lastMatchRanOffMain)
        XCTAssertEqual(notificationCount, 2, "The same held work must notify a live owner")
    }

    private func makeController() -> EditorFindController {
        let controller = EditorFindController(
            documentBinding: EditorFindDocumentBinding(
                identity: EditorDocumentIdentity(rawValue: "find-lifetime"),
                text: "one needle two",
                revision: 1
            )
        )
        controller.debounceNanoseconds = 0
        return controller
    }
}
