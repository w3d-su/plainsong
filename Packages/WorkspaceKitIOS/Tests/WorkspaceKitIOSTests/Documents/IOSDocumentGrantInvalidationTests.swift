import Foundation
@testable import WorkspaceKitIOS
import XCTest

/// The document store and the real access service. A scripted lease's
/// `release()` is a different gate from `service.invalidate`.
@MainActor
final class IOSDocumentGrantInvalidationTests: XCTestCase {
    func testInvalidateBlocksTheNextSaveAndKeepsTheScope() async throws {
        let fixture = try await GrantStoreFixture()
        let handle = try await fixture.open(text: "original")
        handle.session.replaceText("draft")
        let generation = fixture.service.invalidate(fixture.grant.workspaceID)

        XCTAssertGreaterThan(generation, fixture.lease.grant.accessGeneration)
        XCTAssertFalse(fixture.lease.isReleased)
        XCTAssertEqual(fixture.harness.scope.endCount, 0)
        if case let .ready(canWrite, _) = fixture.store.state(for: handle.identity) {
            XCTAssertFalse(canWrite)
        } else {
            XCTFail("invalidation must fence the open document in the same turn")
        }

        let writtenBefore = fixture.port(for: handle)?.written.count ?? -1
        do {
            _ = try await fixture.store.save(handle.identity)
            XCTFail("invalidated grant must not start a save")
        } catch let error as IOSDocumentFailure {
            XCTAssertEqual(error, .documentChanged)
        }
        XCTAssertEqual(fixture.port(for: handle)?.written.count, writtenBefore)
        XCTAssertEqual(handle.session.text, "draft")
        XCTAssertTrue(handle.session.isDirty)
        XCTAssertFalse(fixture.events.contains { event in
            if case .saveCompleted = event {
                return true
            }
            return false
        })
    }

    func testInvalidateRejectsAnInFlightSaveCompletion() async throws {
        let fixture = try await GrantStoreFixture()
        let handle = try await fixture.open(text: "original")
        handle.session.replaceText("draft")
        let port = try XCTUnwrap(fixture.port(for: handle))
        port.blocksSaves = true
        let entered = expectation(description: "save entered")
        port.onSaveEntered = { entered.fulfill() }
        let saving = Task { try await fixture.store.save(handle.identity) }
        await fulfillment(of: [entered], timeout: 2)

        _ = fixture.service.invalidate(fixture.grant.workspaceID)
        XCTAssertFalse(fixture.lease.isReleased)
        XCTAssertEqual(fixture.harness.scope.endCount, 0)
        port.releaseOne()

        do {
            _ = try await saving.value
            XCTFail("completion after invalidate must not acknowledge saved")
        } catch let error as IOSDocumentFailure {
            XCTAssertEqual(error, .documentChanged)
        }
        XCTAssertEqual(handle.session.text, "draft")
        XCTAssertTrue(handle.session.isDirty)
        XCTAssertNotEqual(handle.session.text, "original")
        XCTAssertFalse(fixture.events.contains { event in
            if case .saveCompleted = event {
                return true
            }
            return false
        })
        if case let .ready(canWrite, accessGeneration) = fixture.store.state(for: handle.identity) {
            XCTAssertFalse(canWrite)
            XCTAssertEqual(accessGeneration, fixture.lease.grant.accessGeneration)
        } else {
            XCTFail("refused completion must leave the draft ready and unwritable")
        }
    }

    func testInvalidateDuringSavingNotificationDoesNotStartTheWrite() async throws {
        let fixture = try await GrantStoreFixture()
        let handle = try await fixture.open(text: "original")
        handle.session.replaceText("draft")
        let port = try XCTUnwrap(fixture.port(for: handle))
        var sawSaving = false
        _ = fixture.store.observe { event in
            guard case let .stateChanged(_, _, state) = event, case .saving = state, !sawSaving else { return }
            sawSaving = true
            _ = fixture.service.invalidate(fixture.grant.workspaceID)
        }

        do {
            _ = try await fixture.store.save(handle.identity)
            XCTFail("invalidation inside the saving notification must not write")
        } catch let error as IOSDocumentFailure {
            XCTAssertEqual(error, .documentChanged)
        }
        XCTAssertTrue(sawSaving)
        XCTAssertEqual(port.written.count, 0)
        XCTAssertFalse(fixture.lease.isReleased)
        XCTAssertEqual(fixture.harness.scope.endCount, 0)
        XCTAssertEqual(handle.session.text, "draft")
        XCTAssertTrue(handle.session.isDirty)
        XCTAssertFalse(fixture.events.contains { event in
            if case .saveCompleted = event {
                return true
            }
            return false
        })
        if case let .ready(canWrite, _) = fixture.store.state(for: handle.identity) {
            XCTAssertFalse(canWrite)
        } else {
            XCTFail("refused save must leave the draft ready, not saving")
        }
    }
}

@MainActor
private final class GrantStoreFixture {
    let harness = AccessHarness()
    let ports = ScriptedPortFactory()
    let store: IOSUIDocumentStore
    let grant: IOSWorkspaceGrant
    let lease: IOSRetainedAccessLease
    let service: IOSWorkspaceAccessService
    private(set) var events: [IOSDocumentEvent] = []

    init() async throws {
        service = harness.service
        grant = try await harness.openDirectory("/tmp/plainsong-doc-grant/\(UUID().uuidString)")
        let acquired = try service.acquireLease(for: grant)
        lease = try XCTUnwrap(acquired as? IOSRetainedAccessLease)
        let ports = ports
        store = IOSUIDocumentStore(
            coordinatedAccess: ScriptedCoordinator(),
            recovery: ScriptedRecovery(),
            timing: .quiet,
            filePortFactory: { url in ports.make(fileURL: url) }
        )
        _ = store.observe { [weak self] event in
            self?.events.append(event)
        }
    }

    func open(text: String) async throws -> IOSDocumentHandle {
        ports.openedData = Data(text.utf8)
        let location = harness.location(grant: grant, relativePath: "Note.md")
        return try await store.open(location, lease: lease)
    }

    func port(for handle: IOSDocumentHandle) -> ScriptedFilePort? {
        ports.port(fileURL: handle.location.fileURL)
    }
}
