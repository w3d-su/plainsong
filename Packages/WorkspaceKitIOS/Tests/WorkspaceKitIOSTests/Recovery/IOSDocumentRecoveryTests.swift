import Foundation
import MarkdownCore
@testable import WorkspaceKitIOS
import XCTest

final class IOSDocumentRecoveryTests: XCTestCase {
    func testRecoverySurvivesStoreRecreationAndRejectsEarlyDiscard() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainsong-recovery-\(UUID().uuidString)", isDirectory: true)
        let first = IOSDocumentRecoveryStore(directory: directory)
        let record = IOSRecoveryRecord(
            recordID: UUID(),
            operationID: UUID(),
            documentID: UUID(),
            revisionVersion: 3,
            workspaceID: UUID(),
            accessGeneration: 8,
            resourceID: Data("file".utf8),
            relativePathUTF8: Data("Note.md".utf8),
            fileURLPath: "/Notes/Note.md",
            source: "draft 繁中 👩🏽‍💻",
            baseline: "base",
            reason: .externalConflict
        )
        let receipt = try await first.persist(record)
        let second = IOSDocumentRecoveryStore(directory: directory)
        let listed = await second.list()
        let restored = try XCTUnwrap(listed.records.first { $0.recordID == receipt.recordID })
        XCTAssertEqual(restored.source, record.source)
        XCTAssertEqual(restored.baseline, record.baseline)
        XCTAssertEqual(restored.documentID, record.documentID)
        XCTAssertEqual(restored.revisionVersion, 3)

        do {
            try await second.discard(
                recordID: receipt.recordID,
                persistedText: "nope",
                liveText: record.source,
                liveVersion: 3
            )
            XCTFail("discard without the saved source must fail")
        } catch let error as IOSRecoveryDiscardError {
            XCTAssertEqual(error, .contentNotConfirmed)
        }
        do {
            try await second.discard(
                recordID: receipt.recordID,
                persistedText: record.source,
                liveText: "newer local",
                liveVersion: 4
            )
            XCTFail("a newer local revision must keep recovery")
        } catch let error as IOSRecoveryDiscardError {
            XCTAssertEqual(error, .newerLocalRevision)
        }
        let stillThere = await second.list()
        XCTAssertEqual(stillThere.records.count, 1)
        try await second.discard(
            recordID: receipt.recordID,
            persistedText: record.source,
            liveText: record.source,
            liveVersion: 4
        )
        let after = await second.list()
        XCTAssertTrue(after.records.isEmpty)
        try? FileManager.default.removeItem(at: directory)
    }

    func testCorruptRecoveryDoesNotDropSiblingOrLiveSource() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainsong-recovery-\(UUID().uuidString)", isDirectory: true)
        let store = IOSDocumentRecoveryStore(directory: directory)
        let record = IOSRecoveryRecord(
            recordID: UUID(),
            operationID: UUID(),
            documentID: UUID(),
            revisionVersion: 1,
            workspaceID: UUID(),
            accessGeneration: 1,
            resourceID: nil,
            relativePathUTF8: Data("Note.md".utf8),
            fileURLPath: "/Notes/Note.md",
            source: "good",
            baseline: "base",
            reason: .backgroundDeadline
        )
        _ = try await store.persist(record)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let corrupt = directory.appendingPathComponent("not-a-record.recovery.json")
        try Data("not json".utf8).write(to: corrupt)
        let listed = await store.list()
        XCTAssertEqual(listed.records.map(\.source), ["good"])
        XCTAssertEqual(listed.corruptNames, ["not-a-record.recovery.json"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: corrupt.path))
        let reloaded = try await store.load(record.recordID)
        XCTAssertEqual(reloaded.source, "good")
        try? FileManager.default.removeItem(at: directory)
    }

    func testDiskFullPersistThrowsAndLeavesNoReceiptFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainsong-recovery-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = IOSDocumentRecoveryStore(directory: directory)
        // Simulate a failed durable write by making the parent unwritable after creation.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        let record = sampleRecord()
        do {
            _ = try await store.persist(record)
            XCTFail("unwritable recovery directory must not report success")
        } catch let error as IOSDocumentFailure {
            XCTAssertEqual(error, .recoveryFailed)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(names.contains("\(record.recordID.uuidString.lowercased()).recovery.json"))
        try? FileManager.default.removeItem(at: directory)
    }

    @MainActor
    func testDocumentStoreRecreationReadsRecoveryAndPreservesCorruptSibling() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-read-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = IOSDocumentRecoveryStore(directory: directory)
        let record = sampleRecord(source: "繁中 👩🏽‍💻\r\né e\u{301}\n")
        _ = try await writer.persist(record)
        try Data("bad record".utf8).write(to: directory.appendingPathComponent("broken.recovery.json"))
        let first = DocumentIOHarness(recovery: writer)
        let initial = try await first.store.loadRecovery(recordID: record.recordID)
        let recreated = DocumentIOHarness(recovery: IOSDocumentRecoveryStore(directory: directory))
        let listed = await recreated.store.recoveryList()
        let read = try await recreated.store.loadRecovery(recordID: record.recordID)
        XCTAssertEqual(listed.records.map(\.recordID), [record.recordID])
        XCTAssertEqual(listed.corruptNames, ["broken.recovery.json"])
        XCTAssertTrue(ExactSourceText.matches(read.source, initial.source))
        XCTAssertTrue(ExactSourceText.matches(read.source, record.source))
        XCTAssertEqual(read.documentID, initial.documentID)
        XCTAssertEqual(read.revisionVersion, initial.revisionVersion)
        XCTAssertTrue(FileManager.default
            .fileExists(atPath: directory.appendingPathComponent("broken.recovery.json").path))
    }

    @MainActor
    func testDocumentStoreRecoveryReadRejectsMismatchedRecordIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-identity-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let requested = UUID()
        let misplaced = sampleRecord()
        let url = directory.appendingPathComponent("\(requested.uuidString.lowercased()).recovery.json")
        try JSONEncoder().encode(misplaced).write(to: url)
        let harness = DocumentIOHarness(recovery: IOSDocumentRecoveryStore(directory: directory))
        do {
            _ = try await harness.store.loadRecovery(recordID: requested)
            XCTFail("read must not retarget a different record")
        } catch {
            XCTAssertEqual(error as? IOSRecoveryDiscardError, .corrupt)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    private func sampleRecord(source: String = "draft") -> IOSRecoveryRecord {
        IOSRecoveryRecord(
            recordID: UUID(),
            operationID: UUID(),
            documentID: UUID(),
            revisionVersion: 2,
            workspaceID: UUID(),
            accessGeneration: 1,
            resourceID: nil,
            relativePathUTF8: Data("Note.md".utf8),
            fileURLPath: "/Notes/Note.md",
            source: source,
            baseline: "base",
            reason: .saveIndeterminate
        )
    }
}
