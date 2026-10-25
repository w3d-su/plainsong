import Foundation
@testable import PlainsongIOS
import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSRecoveryControllerTests: XCTestCase {
    func testLateSelectionReadCannotReplaceTheNewerDetail() async {
        let first = recoveryRecord(source: "first")
        let second = recoveryRecord(source: "second")
        let latch = IOSSceneControllerLatch()
        let entered = expectation(description: "old selection parked")
        let fixture = IOSSceneControllerFixture()
        let controller = IOSRecoveryController(list: { IOSRecoveryList(records: [first, second], corruptNames: []) },
                                               load: { identity in
                                                   if identity == first.recordID {
                                                       entered.fulfill()
                                                       await latch.wait()
                                                       return first
                                                   }
                                                   return second
                                               }, capture: fixture.controller.captureRecoveryRestore,
                                               restore: { _, _, _ in XCTFail("no restore requested") })
        let oldRead = Task { await controller.select(first.recordID) }
        await fulfillment(of: [entered], timeout: 2)
        await controller.select(second.recordID)
        latch.release()
        await oldRead.value
        XCTAssertEqual(controller.detail?.recordID, second.recordID)
        XCTAssertEqual(controller.detail?.source, "second")
    }

    func testCancelledAndLateFolderCompletionsCannotRestoreANewIssuance() async throws {
        let record = recoveryRecord()
        let fixture = IOSSceneControllerFixture()
        var restores = 0
        let controller = IOSRecoveryController(list: { IOSRecoveryList(records: [record], corruptNames: []) },
                                               load: { _ in record },
                                               capture: fixture.controller.captureRecoveryRestore,
                                               restore: { _, _, _ in restores += 1 })
        await controller.select(record.recordID)
        controller.requestRestore()
        let old = try XCTUnwrap(controller.pickerRequest)
        XCTAssertNil(controller.completePicker(old, urls: []))
        controller.requestRestore()
        let fresh = try XCTUnwrap(controller.pickerRequest)
        XCTAssertNil(controller.completePicker(old, urls: [URL(fileURLWithPath: "/tmp/old")]))
        XCTAssertEqual(controller.pickerRequest?.id, fresh.id)
        XCTAssertEqual(restores, 0)
        controller.cancelPicker()
        XCTAssertNil(controller.completePicker(fresh, urls: [URL(fileURLWithPath: "/tmp/new")]))
        XCTAssertEqual(restores, 0)
        XCTAssertTrue(fixture.store.opened.isEmpty)
    }

    func testCorruptReadShowsAnErrorWithoutLosingReadableSiblings() async {
        let record = recoveryRecord()
        let fixture = IOSSceneControllerFixture()
        let controller = IOSRecoveryController(list: {
            IOSRecoveryList(records: [record], corruptNames: ["corrupt.recovery.json"])
        }, load: { identity in
            if identity != record.recordID {
                throw IOSRecoveryDiscardError.corrupt
            }
            return record
        }, capture: fixture.controller.captureRecoveryRestore, restore: { _, _, _ in XCTFail("no restore") })
        await controller.refresh()
        XCTAssertEqual(controller.records.count, 1)
        XCTAssertEqual(controller.corruptCount, 1)
        await controller.select(UUID())
        XCTAssertNil(controller.detail)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertEqual(controller.records.count, 1)
        await controller.select(record.recordID)
        XCTAssertEqual(controller.detail?.source, record.source)
        XCTAssertNil(controller.errorMessage)
        XCTAssertTrue(fixture.store.opened.isEmpty)
    }
}
