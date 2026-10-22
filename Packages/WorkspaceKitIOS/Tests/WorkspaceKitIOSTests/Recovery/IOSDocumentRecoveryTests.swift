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

    private func sampleRecord() -> IOSRecoveryRecord {
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
            source: "draft",
            baseline: "base",
            reason: .saveIndeterminate
        )
    }
}
