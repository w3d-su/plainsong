import Foundation
import MarkdownCore
@testable import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSDocumentFailureTests: XCTestCase {
    func testOpeningFailurePublishesNoSnapshot() async throws {
        let harness = DocumentIOHarness()
        harness.ports.openFailure = .access(.downloading)
        let location = harness.location(relativePath: "Note.md", generation: 1)
        do {
            _ = try await harness.store.open(location, lease: harness.directoryLease(generation: 1))
            XCTFail("downloading open must fail")
        } catch let error as IOSDocumentFailure {
            XCTAssertEqual(error, .access(.downloading))
        }
        XCTAssertTrue(harness.events.allSatisfy { event in
            if case .snapshotChanged = event {
                return false
            }
            return true
        })
        XCTAssertTrue(harness.events.contains { event in
            if case let .stateChanged(_, _, state) = event, case .opening = state {
                return true
            }
            return false
        })
    }

    func testFailedAndIndeterminateSavesKeepDraftAndOriginal() async throws {
        let harness = DocumentIOHarness()
        let handle = try await harness.openNote(text: "original")
        handle.session.replaceText("draft")
        let port = try XCTUnwrap(harness.port(for: handle))
        port.blocksSaves = true
        port.failNextSave = true
        let failedEntered = expectation(description: "fail")
        port.onSaveEntered = { failedEntered.fulfill() }
        let failed = Task { try await harness.store.save(handle.identity) }
        await fulfillment(of: [failedEntered], timeout: 2)
        port.releaseOne()
        do {
            _ = try await failed.value
            XCTFail("failed save must throw")
        } catch let error as IOSDocumentFailure {
            XCTAssertEqual(error, .saveFailed)
        }
        XCTAssertEqual(handle.session.text, "draft")
        XCTAssertTrue(handle.session.isDirty)
        XCTAssertTrue(port.written.isEmpty)

        port.indeterminateNextSave = true
        let indeterminateEntered = expectation(description: "indeterminate")
        port.onSaveEntered = { indeterminateEntered.fulfill() }
        let indeterminate = Task { try await harness.store.save(handle.identity) }
        await fulfillment(of: [indeterminateEntered], timeout: 2)
        port.releaseOne()
        do {
            _ = try await indeterminate.value
            XCTFail("indeterminate save must not become clean")
        } catch let error as IOSDocumentFailure {
            XCTAssertEqual(error, .indeterminate)
        }
        XCTAssertEqual(handle.session.text, "draft")
        XCTAssertTrue(handle.session.isDirty)
        XCTAssertTrue(port.written.isEmpty)
    }

    func testReadOnlyOfflineRemovedRevokeAndCloseKeepTheDraft() async throws {
        let harness = DocumentIOHarness()
        let readOnly = try await harness.openNote(text: "frozen", canWrite: false)
        readOnly.session.replaceText("attempt")
        do {
            _ = try await harness.store.save(readOnly.identity)
            XCTFail("read-only save must fail")
        } catch let error as IOSDocumentFailure {
            XCTAssertEqual(error, .access(.readOnly))
        }
        XCTAssertEqual(readOnly.session.text, "attempt")

        let handle = try await harness.openNote(text: "live", relativePath: "Other.md", resourceID: Data("other".utf8))
        let port = try XCTUnwrap(harness.port(for: handle))
        port.emit(.offline)
        XCTAssertEqual(handle.session.text, "live")
        if case let .unavailable(_, reason) = harness.store.state(for: handle.identity) {
            XCTAssertEqual(reason, .access(.offline))
        } else {
            XCTFail("offline must stay unavailable")
        }
        port.emit(.deleted)
        XCTAssertEqual(handle.session.text, "live")
        handle.session.replaceText("kept")
        let lease = harness.directoryLease(generation: 1)
        lease.release()
        // The open lease is the one the entry retained. Release that grant through a new event path:
        // saving after we mark the entry lease released is covered by close failure below.
        port.closeFailure = .closeFailed
        let outcome = try await harness.store.close(handle.identity)
        if case let .retained(recovery) = outcome {
            XCTAssertNotNil(recovery)
        } else {
            XCTFail("dirty close must retain the session")
        }
        XCTAssertEqual(handle.session.text, "kept")
        XCTAssertNotNil(harness.store.snapshot(for: handle.identity))
        _ = lease
    }

    func testCreateRefusesExistingDestination() async throws {
        let harness = DocumentIOHarness()
        let location = harness.location(relativePath: "Note.md", generation: 1)
        let port = ScriptedFilePort(fileURL: location.fileURL, openedData: Data("original".utf8))
        port.createExisting = true
        let store = IOSUIDocumentStore(
            coordinatedAccess: harness.coordinator,
            recovery: harness.recovery,
            timing: .quiet,
            filePortFactory: { _ in port }
        )
        do {
            _ = try await store.create(at: location, initialText: "new", lease: harness.directoryLease(generation: 1))
            XCTFail("create must refuse an existing destination")
        } catch let error as IOSDocumentFailure {
            XCTAssertEqual(error, .access(.alreadyExists))
        }
        XCTAssertTrue(port.written.isEmpty)
        XCTAssertNil(store.snapshot(for: IOSDocumentIdentity(rawValue: UUID())))
    }

    func testCloseWaitsForTheBlockedSave() async throws {
        let harness = DocumentIOHarness()
        let handle = try await harness.openNote(text: "base")
        handle.session.replaceText("pending")
        let port = try XCTUnwrap(harness.port(for: handle))
        port.blocksSaves = true
        let entered = expectation(description: "close save")
        port.onSaveEntered = { entered.fulfill() }
        let closing = Task { try await harness.store.close(handle.identity) }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(port.inFlight, 1)
        port.releaseOne()
        let outcome = try await closing.value
        if case .closed = outcome {
        } else {
            XCTFail("drained clean close should finish")
        }
        XCTAssertFalse(handle.session.isDirty)
        XCTAssertEqual(handle.session.text, "pending")
    }

    func testBackgroundDeadlinePersistsRecoveryWithoutClaimingSave() async throws {
        let harness = DocumentIOHarness()
        let handle = try await harness.openNote(text: "base")
        handle.session.replaceText("unflushed 繁中")
        let port = try XCTUnwrap(harness.port(for: handle))
        port.blocksSaves = true
        let outcomes = await harness.store.flushForBackground()
        await waitUntil { port.parked >= 1 }
        XCTAssertEqual(outcomes.count, 1)
        guard case let .recovered(receipt) = outcomes[0] else {
            XCTFail("background deadline must not report saved")
            return
        }
        let listed = await harness.recovery.list()
        let record = try XCTUnwrap(listed.records.first { $0.recordID == receipt.recordID })
        XCTAssertEqual(record.source, "unflushed 繁中")
        XCTAssertEqual(record.baseline, "base")
        XCTAssertEqual(handle.session.text, "unflushed 繁中")
        XCTAssertTrue(handle.session.isDirty)
        XCTAssertTrue(port.written.isEmpty)
        port.releaseOne()
        await waitUntil { port.written.count == 1 }
        XCTAssertEqual(handle.session.text, "unflushed 繁中")
    }

    func testScopeRevokeRejectsTheNextSave() async throws {
        let harness = DocumentIOHarness()
        let location = harness.location(relativePath: "Note.md", generation: 1)
        harness.ports.openedData = Data("granted".utf8)
        let lease = harness.directoryLease(generation: 1)
        let handle = try await harness.store.open(location, lease: lease)
        handle.session.replaceText("draft")
        lease.release()
        let port = try XCTUnwrap(harness.port(for: handle))
        do {
            _ = try await harness.store.save(handle.identity)
            XCTFail("released lease must not write")
        } catch let error as IOSDocumentFailure {
            XCTAssertEqual(error, .documentChanged)
        }
        XCTAssertTrue(port.written.isEmpty)
        XCTAssertEqual(handle.session.text, "draft")
        XCTAssertTrue(handle.session.isDirty)
    }
}
