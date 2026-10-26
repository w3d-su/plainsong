import Foundation
@testable import PlainsongIOS
import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSRecentAccessPresenterTests: XCTestCase {
    func testAvailableRowSubmitsOnlyItsRecordIDAndDuplicateTapsDoNotQueue() async throws {
        let access = IOSRecentTestAccess()
        let first = access.add(scope: .singleFile)
        let second = access.add(scope: .directory)
        let latch = IOSSceneControllerLatch()
        let started = expectation(description: "One recent operation started")
        var opened: [UUID] = []
        var routes: [IOSWorkspaceScope] = []
        let presenter = IOSRecentAccessPresenter(access: access, openRecent: { id in
            opened.append(id)
            started.fulfill()
            await latch.wait()
        }, chooseAgain: { _ in }, didOpen: { routes.append($0) })

        presenter.open(recordID: first)
        presenter.open(recordID: first)
        presenter.open(recordID: second)
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(opened, [first])
        XCTAssertTrue(presenter.isBusy)
        XCTAssertEqual(presenter.rows.first?.displayName, "../display is not authority")
        latch.release()
        try await waitUntil { !presenter.isBusy }
        XCTAssertEqual(routes, [.singleFile])
    }

    func testCancellationSuppressesLateSuccessAndKeepsBusyUntilDrain() async throws {
        let access = IOSRecentTestAccess()
        let id = access.add(scope: .singleFile)
        let latch = IOSSceneControllerLatch()
        let started = expectation(description: "Open is parked")
        var routes = 0
        var opens = 0
        let presenter = IOSRecentAccessPresenter(access: access, openRecent: { _ in
            opens += 1
            started.fulfill()
            await latch.wait()
        }, chooseAgain: { _ in }, didOpen: { _ in routes += 1 })
        presenter.open(recordID: id)
        await fulfillment(of: [started], timeout: 2)
        presenter.cancelPendingOpen()
        presenter.open(recordID: id)
        XCTAssertTrue(presenter.isBusy)
        XCTAssertEqual(opens, 1)
        latch.release()
        try await waitUntil { !presenter.isBusy }
        XCTAssertEqual(routes, 0)
        XCTAssertNil(presenter.errorMessage)
    }

    func testRemovalDuringOpenSuppressesLateFailureAndRemovesOnlyItsRecord() async throws {
        let access = IOSRecentTestAccess()
        let removed = access.add(scope: .singleFile)
        let retained = access.add(scope: .directory)
        let latch = IOSSceneControllerLatch()
        let started = expectation(description: "Open is parked before a late failure")
        var routes = 0
        let presenter = IOSRecentAccessPresenter(access: access, openRecent: { _ in
            started.fulfill()
            await latch.wait()
            throw IOSWorkspaceFailure.permissionDenied
        }, chooseAgain: { _ in }, didOpen: { _ in routes += 1 })
        presenter.open(recordID: removed)
        await fulfillment(of: [started], timeout: 2)
        presenter.removeRecord(recordID: removed)
        XCTAssertEqual(access.removed, [removed])
        XCTAssertEqual(presenter.rows.map(\.id), [retained])
        latch.release()
        try await waitUntil { !presenter.isBusy }
        XCTAssertEqual(routes, 0)
        XCTAssertNil(presenter.errorMessage)
    }

    func testUnavailableAndRemovedRowsCannotOpenAndChooseAgainPreservesScope() {
        let access = IOSRecentTestAccess()
        let id = access.add(scope: .directory, status: .needsReselection)
        var opens = 0
        var choices: [IOSWorkspaceScope] = []
        let presenter = IOSRecentAccessPresenter(access: access, openRecent: { _ in opens += 1 },
                                                 chooseAgain: { choices.append($0) },
                                                 didOpen: { _ in XCTFail("Unavailable record cannot navigate") })
        presenter.open(recordID: id)
        presenter.chooseAgain(recordID: id)
        XCTAssertEqual(opens, 0)
        XCTAssertEqual(choices, [.directory])
        presenter.removeRecord(recordID: id)
        presenter.open(recordID: id)
        presenter.chooseAgain(recordID: id)
        XCTAssertEqual(opens, 0)
        XCTAssertEqual(choices, [.directory])
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0 ..< 100 {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Recent presentation did not settle")
        throw IOSWorkspaceFailure.unavailable
    }
}
