import Foundation
import MarkdownCore
@testable import Plainsong
import XCTest

final class WorkspaceMutationTextRecoveryStoreTests: XCTestCase {
    func testLoadRoundTripsExactUTF8AndUnicodeAcrossStoreInstances() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanUp() }
        let source = "NFC: \u{00E9}\nNFD: e\u{0301}\r\nEmoji: 👩🏽‍💻🧪\nNUL:\0end"
        let record = try WorkspaceMutationTextRecoveryRecord(
            id: XCTUnwrap(UUID(uuidString: "5C113D00-6AC1-41D1-8D68-FC29AC48B862")),
            originalURL: URL(fileURLWithPath: "/tmp/Cafe\u{0301}/post.md"),
            fileKind: .markdown,
            source: source,
            revision: 42,
            updatedAt: Date(timeIntervalSince1970: 1_725_000_000),
            reason: .trash
        )

        try fixture.store.upsert(record)
        let reloadedStore = WorkspaceMutationTextRecoveryStore(
            directoryURL: fixture.directoryURL
        )
        let loaded = try XCTUnwrap(reloadedStore.load().only)

        XCTAssertEqual(loaded, record)
        XCTAssertTrue(loaded.source.utf8.elementsEqual(source.utf8))
        XCTAssertTrue(
            loaded.originalURL.path(percentEncoded: false).utf8.elementsEqual(
                record.originalURL.path(percentEncoded: false).utf8
            )
        )
    }

    func testUpsertAtomicallyReplacesOneRecordWithItsLatestRevision() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanUp() }
        let id = UUID()
        let original = WorkspaceMutationTextRecoveryRecord(
            id: id,
            originalURL: URL(fileURLWithPath: "/tmp/post.md"),
            fileKind: .markdown,
            source: "Original",
            revision: 1,
            updatedAt: Date(timeIntervalSince1970: 1),
            reason: .trash
        )
        let latest = WorkspaceMutationTextRecoveryRecord(
            id: id,
            originalURL: original.originalURL,
            fileKind: .mdx,
            source: "Latest e\u{0301}",
            revision: 2,
            updatedAt: Date(timeIntervalSince1970: 2),
            reason: .indeterminateMutation
        )

        try fixture.store.upsert(original)
        try fixture.store.upsert(latest)

        XCTAssertEqual(try fixture.store.load(), [latest])
        XCTAssertEqual(try fixture.recordFilenames(), [
            WorkspaceMutationTextRecoveryStore.recordFilename(for: id),
        ])
    }

    func testRemoveIsIdempotentAndDoesNotRemoveOtherRecords() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanUp() }
        let first = fixture.record(source: "First", updatedAt: 1)
        let second = fixture.record(source: "Second", updatedAt: 2)
        try fixture.store.upsert(first)
        try fixture.store.upsert(second)

        try fixture.store.remove(id: first.id)
        try fixture.store.remove(id: first.id)

        XCTAssertEqual(try fixture.store.load(), [second])
    }

    func testQuarantinePreservesExactRecordBytesAndExcludesRecordFromLoad() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanUp() }
        let record = fixture.record(source: "Preserve e\u{0301} 👩🏽‍💻", updatedAt: 3)
        try fixture.store.upsert(record)
        let activeURL = fixture.directoryURL.appendingPathComponent(
            WorkspaceMutationTextRecoveryStore.recordFilename(for: record.id)
        )
        let activeBytes = try Data(contentsOf: activeURL)

        try fixture.store.quarantine(id: record.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: activeURL.path))
        XCTAssertEqual(try fixture.store.load(), [])
        let quarantineFilename = try XCTUnwrap(
            fixture.recordFilenames().only
        )
        XCTAssertTrue(quarantineFilename.hasPrefix(
            "\(WorkspaceMutationTextRecoveryStore.recordFilename(for: record.id))" +
                "-stop-tracking-"
        ))
        XCTAssertTrue(quarantineFilename.hasSuffix(".quarantine"))
        XCTAssertEqual(
            try Data(contentsOf: fixture.directoryURL.appendingPathComponent(
                quarantineFilename
            )),
            activeBytes
        )
    }

    func testLoadRetainsCorruptRecordAndSurfacesFailure() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanUp() }
        let first = fixture.record(source: "First", updatedAt: 1)
        let second = fixture.record(source: "Second", updatedAt: 2)
        try fixture.store.upsert(first)
        try fixture.store.upsert(second)
        let corruptID = UUID()
        let corruptURL = fixture.directoryURL.appendingPathComponent(
            WorkspaceMutationTextRecoveryStore.recordFilename(for: corruptID)
        )
        try Data("not a property list".utf8).write(to: corruptURL)

        XCTAssertThrowsError(try fixture.store.load())
        XCTAssertTrue(FileManager.default.fileExists(atPath: corruptURL.path))
    }

    func testQuarantineAfterLoadFailurePreservesUnreadableBytesAndAllowsCleanStore() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanUp() }
        let corruptID = UUID()
        let corruptBytes = Data("unreadable recovery bytes".utf8)
        let corruptFilename = WorkspaceMutationTextRecoveryStore.recordFilename(
            for: corruptID
        )
        let corruptURL = fixture.directoryURL.appendingPathComponent(
            corruptFilename
        )
        try corruptBytes.write(to: corruptURL)
        XCTAssertThrowsError(try fixture.store.load())

        try fixture.store.quarantineAfterLoadFailure()

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.directoryURL.path
        ))
        let quarantineNames = try FileManager.default.contentsOfDirectory(
            atPath: fixture.containerURL.path
        ).filter {
            $0.hasPrefix("\(fixture.directoryURL.lastPathComponent)-unreadable-")
        }
        let quarantineName = try XCTUnwrap(quarantineNames.only)
        let preservedURL = fixture.containerURL
            .appendingPathComponent(quarantineName, isDirectory: true)
            .appendingPathComponent(corruptFilename, isDirectory: false)
        XCTAssertEqual(try Data(contentsOf: preservedURL), corruptBytes)

        let cleanRecord = fixture.record(source: "Clean recovery", updatedAt: 3)
        try fixture.store.upsert(cleanRecord)
        XCTAssertEqual(try fixture.store.load(), [cleanRecord])
        XCTAssertEqual(try Data(contentsOf: preservedURL), corruptBytes)
    }

    func testLoadRetainsFilenameIdentityMismatchAndSurfacesFailure() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanUp() }
        let retained = fixture.record(source: "Retained", updatedAt: 1)
        let mismatched = fixture.record(source: "Mismatched", updatedAt: 2)
        try fixture.store.upsert(retained)
        try fixture.store.upsert(mismatched)
        let mismatchedURL = fixture.directoryURL.appendingPathComponent(
            WorkspaceMutationTextRecoveryStore.recordFilename(for: UUID())
        )
        let originalURL = fixture.directoryURL.appendingPathComponent(
            WorkspaceMutationTextRecoveryStore.recordFilename(for: mismatched.id)
        )
        try FileManager.default.moveItem(at: originalURL, to: mismatchedURL)

        XCTAssertThrowsError(try fixture.store.load())
        XCTAssertTrue(FileManager.default.fileExists(atPath: mismatchedURL.path))
    }

    func testLoadReturnsEmptyWithoutCreatingRecoveryDirectory() throws {
        let fixture = try StoreFixture(createDirectory: false)
        defer { fixture.cleanUp() }

        XCTAssertEqual(try fixture.store.load(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directoryURL.path))
    }

    func testUpsertCreatesMissingRecoveryDirectoryThroughSharedDurableHelper() throws {
        let fixture = try StoreFixture(createDirectory: false)
        defer { fixture.cleanUp() }
        let record = fixture.record(source: "Recovered", updatedAt: 1)

        try fixture.store.upsert(record)

        XCTAssertEqual(try fixture.store.load(), [record])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.directoryURL.path
        ))
    }
}

private final class StoreFixture {
    let containerURL: URL
    let directoryURL: URL
    let store: WorkspaceMutationTextRecoveryStore

    init(createDirectory: Bool = true) throws {
        containerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceMutationTextRecoveryStoreTests")
            .appendingPathComponent(UUID().uuidString)
        directoryURL = containerURL.appendingPathComponent("Recovery", isDirectory: true)
        if createDirectory {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
        }
        store = WorkspaceMutationTextRecoveryStore(directoryURL: directoryURL)
    }

    func record(source: String, updatedAt: TimeInterval) -> WorkspaceMutationTextRecoveryRecord {
        WorkspaceMutationTextRecoveryRecord(
            originalURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).md"),
            fileKind: .markdown,
            source: source,
            revision: Int(updatedAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            reason: .trash
        )
    }

    func recordFilenames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directoryURL.path).sorted()
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: containerURL)
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}
