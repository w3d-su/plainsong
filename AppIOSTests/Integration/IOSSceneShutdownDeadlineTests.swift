import Foundation
@testable import PlainsongIOS
import WorkspaceKitIOS
import XCTest

final class IOSSceneShutdownDeadlineTests: XCTestCase {
    @MainActor
    func testDisconnectDeadlineRetainsParkedWriterUntilItsProviderDrains() async throws {
        let fixture = IOSSceneControllerFixture()
        let latch = IOSSceneControllerLatch()
        defer { latch.release() }
        fixture.store.openLatch = latch
        let started = expectation(description: "Provider owns open admission")
        fixture.store.onOpen = { started.fulfill() }
        let opening = Task { @MainActor in
            try await fixture.controller.openPickedURL(fixture.selectedURL, scope: .singleFile)
        }
        await fulfillment(of: [started], timeout: 2)
        let ticket = try XCTUnwrap(fixture.controller.admission.active)

        let closed = await fixture.controller.shutdown(transitionWait: .zero)

        XCTAssertFalse(closed)
        XCTAssertFalse(fixture.controller.isDisposed)
        XCTAssertFalse(fixture.controller.isShuttingDown)
        XCTAssertTrue(fixture.controller.transitioning)
        XCTAssertEqual(fixture.controller.admission.active, ticket)
        XCTAssertEqual(fixture.store.flushCount, 0)
        XCTAssertTrue(fixture.store.closed.isEmpty)
        XCTAssertTrue(fixture.workspace.invalidated.isEmpty)
        XCTAssertEqual(fixture.preview.invalidateCount, 0)
        latch.release()
        try await opening.value
        XCTAssertNotNil(fixture.controller.handle)
        let retried = await fixture.controller.shutdown()
        XCTAssertTrue(retried)
        XCTAssertNil(fixture.controller.admission.active)
    }
}
