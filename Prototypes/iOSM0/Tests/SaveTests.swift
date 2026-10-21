@testable import PlainsongIOSM0
import XCTest

final class SaveTests: XCTestCase {
    func testCanonicallyEquivalentUnicodeStillDirtyWhenBytesDiffer() {
        var ledger = SaveLedger(documentID: UUID(), source: "é")
        ledger.observe(source: "é", revision: 1)
        XCTAssertTrue(ledger.dirty)
        XCTAssertFalse(sameSource(ledger.source, ledger.savedSource))
    }

    func testOldSaveAcknowledgementLeavesNewRevisionDirty() throws {
        var ledger = SaveLedger(documentID: UUID(), source: "原稿")
        ledger.observe(source: "N 中文", revision: 1)
        let capture = try XCTUnwrap(ledger.begin())
        ledger.observe(source: "N+1 👩🏽‍💻", revision: 2)
        XCTAssertTrue(ledger.complete(capture, success: true))
        XCTAssertEqual(ledger.source, "N+1 👩🏽‍💻")
        XCTAssertEqual(ledger.savedSource, "N 中文")
        XCTAssertTrue(ledger.dirty)
    }

    func testFailedSavePreservesBaselineAndSource() throws {
        var ledger = SaveLedger(documentID: UUID(), source: "baseline")
        ledger.observe(source: "draft", revision: 1)
        let capture = try XCTUnwrap(ledger.begin())
        XCTAssertTrue(ledger.complete(capture, success: false))
        XCTAssertEqual(ledger.savedSource, "baseline")
        XCTAssertEqual(ledger.source, "draft")
        XCTAssertTrue(ledger.dirty)
    }

    func testOnlyOneWriterAndDuplicateAcknowledgementRefused() throws {
        var ledger = SaveLedger(documentID: UUID(), source: "a")
        let capture = try XCTUnwrap(ledger.begin())
        XCTAssertNil(ledger.begin())
        XCTAssertTrue(ledger.complete(capture, success: true))
        ledger.observe(source: "b", revision: 1)
        let next = try XCTUnwrap(ledger.begin())
        XCTAssertFalse(ledger.complete(capture, success: true))
        XCTAssertEqual(ledger.active, next)
    }

    func testConflictAndUnavailableRefuseOverwrite() {
        var ledger = SaveLedger(documentID: UUID(), source: "a")
        ledger.conflict = true
        XCTAssertNil(ledger.begin())
        ledger.conflict = false
        ledger.available = false
        XCTAssertNil(ledger.begin())
    }

    func testRecoveryRoundTripExactUnicodeAndRevision() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecoveryStore(directory: directory)
        let snapshot = RecoveryEnvelope(documentID: UUID(), revision: 7, source: "中文\n👩🏽‍💻 é",
                                        reason: "background", time: Date(timeIntervalSince1970: 100))
        try store.persist(snapshot)
        XCTAssertEqual(try store.readAll(), [snapshot])
    }

    func testRecoveryFailureDoesNotReturnSuccess() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        try Data("file".utf8).write(to: path)
        let store = RecoveryStore(directory: path)
        XCTAssertThrowsError(try store.persist(RecoveryEnvelope(documentID: UUID(), revision: 1,
                                                                source: "draft", reason: "failure", time: Date())))
    }
}
