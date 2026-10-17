import Darwin
import Foundation
@testable import WorkspaceKit
import XCTest

/// A file-only App Sandbox grant refuses a new entry in the document's parent (`EPERM`) but
/// permits a cross-directory `RENAME_SWAP` of the granted leaf. POSIX permissions cannot express
/// that combination, so these tests refuse the sibling create through the injected call and
/// stage in a real separate directory; the last test denies the parent through POSIX instead.
extension WorkspaceAnchoredFileSystemTests {
    func testFolderGrantSaveKeepsSiblingStagingAndNeverAsksForSeparateDirectory() throws {
        let fixture = try makeWriteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let originalIdentity = try XCTUnwrap(fixture.originalIdentity)
        let staging = StagingDirectoryRecorder()
        let recorder = WorkspaceInjectedCallRecorder(failures: [:])

        let outcome = write(
            to: fixture,
            expecting: .existing(originalIdentity),
            hooks: recorder.hooks(
                eventHandler: staging.record,
                itemReplacementDirectory: staging.provider { _ in
                    XCTFail("A writable parent must not request a separate staging directory")
                    throw CocoaError(.fileWriteNoPermission)
                }
            )
        )

        XCTAssertNotNil(requireDurable(outcome))
        XCTAssertEqual(try writeText(at: fixture.destination), "replacement bytes")
        XCTAssertFalse(staging.anchoredSeparateDirectory)
        XCTAssertTrue(recorder.calls.contains(.createSiblingTemporary))
        try assertNoWriteArtifacts(for: fixture)
    }

    func testRefusedSiblingCreateSavesThroughSeparateStagingDirectory() throws {
        let fixture = try makeWriteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let originalIdentity = try XCTUnwrap(fixture.originalIdentity)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o640],
            ofItemAtPath: fixture.destination.path
        )
        let stagingURL = try makeStagingDirectory(in: fixture)
        let staging = StagingDirectoryRecorder()
        let recorder = WorkspaceInjectedCallRecorder(failures: [.createSiblingTemporary: .unreadable])

        let outcome = write(
            to: fixture,
            expecting: .existingContent(
                originalIdentity,
                sha256Digest: WorkspaceAnchoredFileSystem.sha256Digest(Data("original".utf8))
            ),
            hooks: recorder.hooks(
                eventHandler: staging.record,
                itemReplacementDirectory: staging.provider { _ in stagingURL }
            )
        )

        let result = try XCTUnwrap(requireDurable(outcome))
        XCTAssertEqual(result.cleanupState, .none)
        XCTAssertTrue(staging.anchoredSeparateDirectory)
        XCTAssertEqual(staging.requestedDestinations, [fixture.location.fileURL])
        XCTAssertEqual(try writeText(at: fixture.destination), "replacement bytes")
        let committedIdentity = try writeFileIdentity(at: fixture.destination)
        XCTAssertNotEqual(committedIdentity, originalIdentity, "Publication replaces the inode")
        XCTAssertEqual(result.metadata.identity, committedIdentity)
        XCTAssertEqual(try noFollowStatus(at: fixture.destination).st_mode & 0o777, 0o640)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: stagingURL.path),
            "The emptied staging directory is removed"
        )
        try assertNoWriteArtifacts(for: fixture)
        try assertFixtureSentinel(fixture)
    }

    func testRefusedSiblingCreateUsesFoundationItemReplacementDirectoryByDefault() throws {
        let fixture = try makeWriteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let originalIdentity = try XCTUnwrap(fixture.originalIdentity)
        let staging = StagingDirectoryRecorder()
        let recorder = WorkspaceInjectedCallRecorder(failures: [.createSiblingTemporary: .unreadable])

        let outcome = write(
            to: fixture,
            expecting: .existing(originalIdentity),
            hooks: recorder.hooks(
                eventHandler: staging.record,
                itemReplacementDirectory: staging.provider { destination in
                    try WorkspaceAnchoredFileSystem.Hooks.production
                        .itemReplacementDirectory(for: destination)
                }
            )
        )

        XCTAssertNotNil(requireDurable(outcome))
        XCTAssertTrue(staging.anchoredSeparateDirectory)
        let returned = try XCTUnwrap(staging.returnedDirectories.first)
        XCTAssertFalse(
            returned.path.hasPrefix(fixture.root.path),
            "Foundation's directory must not be a new entry in the workspace: \(returned.path)"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: returned.path))
        XCTAssertEqual(try writeText(at: fixture.destination), "replacement bytes")
        try assertNoWriteArtifacts(for: fixture)
    }

    func testSeparateStagingRollbackRestoresOriginalAcrossDirectories() throws {
        let fixture = try makeWriteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let originalIdentity = try XCTUnwrap(fixture.originalIdentity)
        let stagingURL = try makeStagingDirectory(in: fixture)
        let staging = StagingDirectoryRecorder()
        let recorder = WorkspaceInjectedCallRecorder(failures: [
            .createSiblingTemporary: .unreadable,
            .validateCommittedLeaf: .namespaceChanged,
        ])

        let outcome = write(
            to: fixture,
            expecting: .existing(originalIdentity),
            hooks: recorder.hooks(
                eventHandler: staging.record,
                itemReplacementDirectory: staging.provider { _ in stagingURL }
            )
        )

        let result = try XCTUnwrap(requireNotCommitted(outcome, reason: .namespaceChanged))
        XCTAssertEqual(result.artifactState, .none)
        XCTAssertTrue(recorder.calls.contains(.renameRollback))
        XCTAssertEqual(try writeText(at: fixture.destination), "original")
        XCTAssertEqual(try writeFileIdentity(at: fixture.destination), originalIdentity)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingURL.path))
        try assertNoWriteArtifacts(for: fixture)
        try assertFixtureSentinel(fixture)
    }

    func testSeparateStagingRetainsUnremovedArtifactInsideStagingDirectory() throws {
        let fixture = try makeWriteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let originalIdentity = try XCTUnwrap(fixture.originalIdentity)
        let stagingURL = try makeStagingDirectory(in: fixture)
        let staging = StagingDirectoryRecorder()
        let recorder = WorkspaceInjectedCallRecorder(failures: [
            .createSiblingTemporary: .unreadable,
            .syncCommittedDirectory: .durabilityFailed,
            .syncRollbackDirectory: .durabilityFailed,
        ])

        let outcome = write(
            to: fixture,
            expecting: .existing(originalIdentity),
            hooks: recorder.hooks(
                eventHandler: staging.record,
                itemReplacementDirectory: staging.provider { _ in stagingURL }
            )
        )

        let result = try XCTUnwrap(requireIndeterminate(outcome, reason: .durabilityFailed))
        let preparedMetadata = try XCTUnwrap(result.preparedMetadata)
        guard case let .retained(artifact) = result.recoveryArtifact else {
            return XCTFail("Expected retained prepared bytes, got \(result.recoveryArtifact)")
        }
        XCTAssertEqual(try writeText(at: fixture.destination), "original")
        XCTAssertEqual(try writeFileIdentity(at: fixture.destination), originalIdentity)
        XCTAssertEqual(
            artifact.fileURL.deletingLastPathComponent().resolvingSymlinksInPath().path,
            stagingURL.resolvingSymlinksInPath().path,
            "The reported recovery location names the staging directory"
        )
        XCTAssertEqual(try writeText(at: artifact.fileURL), "replacement bytes")
        XCTAssertEqual(try writeFileIdentity(at: artifact.fileURL), preparedMetadata.identity)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingURL.path))
        try assertNoWriteArtifacts(for: fixture)
    }

    func testRefusedSiblingCreateForMissingDestinationPublishesExclusivelyAcrossDirectories() throws {
        let fixture = try makeWriteFixture(originalText: nil)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let stagingURL = try makeStagingDirectory(in: fixture)
        let staging = StagingDirectoryRecorder()
        let recorder = WorkspaceInjectedCallRecorder(failures: [.createSiblingTemporary: .unreadable])

        let outcome = write(
            to: fixture,
            expecting: .missing,
            hooks: recorder.hooks(
                eventHandler: staging.record,
                itemReplacementDirectory: staging.provider { _ in stagingURL }
            )
        )

        let result = try XCTUnwrap(requireDurable(outcome))
        XCTAssertEqual(result.cleanupState, .none)
        XCTAssertTrue(recorder.calls.contains(.renameExclusive))
        XCTAssertEqual(try writeText(at: fixture.destination), "replacement bytes")
        XCTAssertEqual(try writeFileIdentity(at: fixture.destination), result.metadata.identity)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingURL.path))
        try assertNoWriteArtifacts(for: fixture)
    }

    func testSeparateStagingRefusesTheDestinationParentAndLeavesItInPlace() throws {
        let fixture = try makeWriteFixture(originalText: nil)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let destinationParent = fixture.destination.deletingLastPathComponent()
        let recorder = WorkspaceInjectedCallRecorder(failures: [.createSiblingTemporary: .unreadable])

        let outcome = write(
            to: fixture,
            expecting: .missing,
            hooks: recorder.hooks(itemReplacementDirectory: { _ in destinationParent })
        )

        let result = try XCTUnwrap(requireNotCommitted(outcome, reason: .unreadable))
        XCTAssertEqual(result.artifactState, .none)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: destinationParent.path, isDirectory: &isDirectory)
                && isDirectory.boolValue,
            "An empty destination parent returned as staging must never be removed"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        try assertNoWriteArtifacts(for: fixture)
    }

    func testUnavailableSeparateStagingDirectoryLeavesDocumentUntouched() throws {
        let fixture = try makeWriteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let originalIdentity = try XCTUnwrap(fixture.originalIdentity)
        let recorder = WorkspaceInjectedCallRecorder(failures: [.createSiblingTemporary: .unreadable])

        let outcome = write(
            to: fixture,
            expecting: .existing(originalIdentity),
            hooks: recorder.hooks(itemReplacementDirectory: { _ in
                throw CocoaError(.fileWriteNoPermission)
            })
        )

        let result = try XCTUnwrap(requireNotCommitted(outcome, reason: .unreadable))
        XCTAssertEqual(result.artifactState, .none)
        XCTAssertEqual(try writeText(at: fixture.destination), "original")
        XCTAssertEqual(try writeFileIdentity(at: fixture.destination), originalIdentity)
        try assertNoWriteArtifacts(for: fixture)
    }

    /// A real permission-denied parent: the sibling create fails with `EACCES`, the write falls
    /// back to a separate directory, and POSIX (unlike a file-only sandbox grant) then also
    /// refuses the cross-directory swap. The document and both directories stay clean.
    func testPermissionDeniedParentFallsBackAndFailsCleanWhenSwapIsAlsoDenied() throws {
        let fixture = try makeWriteFixture()
        let destinationParent = fixture.destination.deletingLastPathComponent()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: destinationParent.path
            )
            try? FileManager.default.removeItem(at: fixture.parent)
        }
        let originalIdentity = try XCTUnwrap(fixture.originalIdentity)
        let stagingURL = try makeStagingDirectory(in: fixture)
        let staging = StagingDirectoryRecorder()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: destinationParent.path
        )
        let probeDescriptor = (destinationParent.path + "/.plainsong-probe").withCString {
            Darwin.open($0, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        }
        let probeError = errno
        if probeDescriptor >= 0 { Darwin.close(probeDescriptor) }
        try XCTSkipIf(probeDescriptor >= 0, "Running as a user that bypasses directory permissions")
        XCTAssertEqual(probeError, EACCES)

        let outcome = write(
            to: fixture,
            expecting: .existing(originalIdentity),
            hooks: WorkspaceAnchoredFileSystem.Hooks(
                eventHandler: staging.record,
                itemReplacementDirectory: staging.provider { _ in stagingURL }
            )
        )

        XCTAssertNotNil(requireNotCommitted(outcome, reason: .unreadable))
        XCTAssertTrue(staging.anchoredSeparateDirectory, "EACCES on the sibling falls back")
        XCTAssertEqual(try writeText(at: fixture.destination), "original")
        XCTAssertEqual(try writeFileIdentity(at: fixture.destination), originalIdentity)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingURL.path))
        try assertNoWriteArtifacts(for: fixture)
        try assertFixtureSentinel(fixture)
    }

    private func makeStagingDirectory(in fixture: WorkspaceWriteFixture) throws -> URL {
        let url = fixture.parent
            .appendingPathComponent("TemporaryItems", isDirectory: true)
            .appendingPathComponent("NSIRD_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class StagingDirectoryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [WorkspaceAnchoredFileSystem.Event] = []
    private var destinations: [URL] = []
    private var directories: [URL] = []

    var anchoredSeparateDirectory: Bool {
        lock.withLock { events.contains(.separateStagingAnchored) }
    }

    var requestedDestinations: [URL] {
        lock.withLock { destinations }
    }

    var returnedDirectories: [URL] {
        lock.withLock { directories }
    }

    func record(_ event: WorkspaceAnchoredFileSystem.Event) {
        lock.withLock { events.append(event) }
    }

    func provider(
        _ body: @escaping @Sendable (URL) throws -> URL
    ) -> @Sendable (URL) throws -> URL {
        { [self] destination in
            lock.withLock { destinations.append(destination) }
            let directory = try body(destination)
            lock.withLock { directories.append(directory) }
            return directory
        }
    }
}
