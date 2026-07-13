import Foundation
@testable import WorkspaceKit
import XCTest

extension WorkspaceAnchoredFileSystemTests {
    func testPostcommitLeafValidationFailureRollsBackBeforeReportingNotCommitted() throws {
        let fixture = try makeWriteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let originalIdentity = try XCTUnwrap(fixture.originalIdentity)
        let recorder = WorkspaceInjectedCallRecorder(
            failures: [.validateCommittedLeaf: .namespaceChanged]
        )

        let outcome = write(
            to: fixture,
            expecting: .existing(originalIdentity),
            hooks: recorder.hooks()
        )

        let result = try XCTUnwrap(requireNotCommitted(outcome, reason: .namespaceChanged))
        XCTAssertEqual(result.artifactState, .none)
        XCTAssertEqual(try writeText(at: fixture.destination), "original")
        XCTAssertEqual(try writeFileIdentity(at: fixture.destination), originalIdentity)
        XCTAssertTrue(recorder.calls.contains(.renameRollback))
        XCTAssertTrue(recorder.calls.contains(.syncRollbackDirectory))
        try assertNoWriteArtifacts(for: fixture)
        try assertFixtureSentinel(fixture)
    }

    func testCommittedDirectorySyncFailureReturnsNotCommittedOnlyAfterDurableRollback() throws {
        let fixture = try makeWriteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let originalIdentity = try XCTUnwrap(fixture.originalIdentity)
        let recorder = WorkspaceInjectedCallRecorder(
            failures: [.syncCommittedDirectory: .durabilityFailed]
        )

        let outcome = write(
            to: fixture,
            expecting: .existing(originalIdentity),
            hooks: recorder.hooks()
        )

        let result = try XCTUnwrap(requireNotCommitted(outcome, reason: .durabilityFailed))
        XCTAssertEqual(result.artifactState, .none)
        XCTAssertEqual(try writeText(at: fixture.destination), "original")
        XCTAssertEqual(try writeFileIdentity(at: fixture.destination), originalIdentity)
        XCTAssertTrue(recorder.calls.contains(.renameRollback))
        XCTAssertTrue(recorder.calls.contains(.syncRollbackDirectory))
        try assertNoWriteArtifacts(for: fixture)
        try assertFixtureSentinel(fixture)
    }

    func testRollbackDirectorySyncFailureReportsIndeterminateAndRetainsPreparedBytes() throws {
        let fixture = try makeWriteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let originalIdentity = try XCTUnwrap(fixture.originalIdentity)
        let recorder = WorkspaceInjectedCallRecorder(failures: [
            .syncCommittedDirectory: .durabilityFailed,
            .syncRollbackDirectory: .durabilityFailed,
        ])

        let outcome = write(
            to: fixture,
            expecting: .existing(originalIdentity),
            hooks: recorder.hooks()
        )

        let result = try XCTUnwrap(requireIndeterminate(outcome, reason: .durabilityFailed))
        let preparedMetadata = try XCTUnwrap(result.preparedMetadata)
        guard case let .retained(artifact) = result.recoveryArtifact else {
            return XCTFail("Expected retained prepared bytes, got \(result.recoveryArtifact)")
        }
        XCTAssertEqual(try writeText(at: fixture.destination), "original")
        XCTAssertEqual(try writeFileIdentity(at: fixture.destination), originalIdentity)
        XCTAssertEqual(try writeText(at: artifact.fileURL), "replacement bytes")
        XCTAssertEqual(try writeFileIdentity(at: artifact.fileURL), preparedMetadata.identity)
        XCTAssertEqual(
            try writeTemporaryURLs(in: fixture.destination.deletingLastPathComponent())
                .map(\.lastPathComponent),
            [artifact.fileURL.lastPathComponent]
        )
        try assertFixtureSentinel(fixture)
    }

    func testMissingCommitDirectorySyncFailureDurablyRemovesCreatedDestination() throws {
        let fixture = try makeWriteFixture(originalText: nil)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let recorder = WorkspaceInjectedCallRecorder(
            failures: [.syncCommittedDirectory: .durabilityFailed]
        )

        let outcome = write(to: fixture, expecting: .missing, hooks: recorder.hooks())

        let result = try XCTUnwrap(requireNotCommitted(outcome, reason: .durabilityFailed))
        XCTAssertEqual(result.artifactState, .none)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertTrue(recorder.calls.contains(.unlinkCreatedDestination))
        XCTAssertTrue(recorder.calls.contains(.syncRollbackDirectory))
        try assertNoWriteArtifacts(for: fixture)
        try assertFixtureSentinel(fixture)
    }

    func testCancellationAfterTemporaryPreparationLeavesOriginalAndCleansTemporaryFile() async throws {
        let fixture = try makeWriteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let originalIdentity = try XCTUnwrap(fixture.originalIdentity)
        let recorder = WorkspaceInjectedCallRecorder(failures: [:])
        let hooks = recorder.hooks { event in
            if event == .temporaryFilePrepared {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        let location = fixture.location

        let outcome = await Task.detached {
            WorkspaceNoFollowFileWriter.write(
                Data("replacement bytes".utf8),
                to: location,
                expecting: .existing(originalIdentity),
                hooks: hooks
            )
        }.value

        let result = try XCTUnwrap(requireNotCommitted(outcome, reason: .cancelled))
        XCTAssertEqual(result.artifactState, .none)
        XCTAssertEqual(try writeText(at: fixture.destination), "original")
        XCTAssertEqual(try writeFileIdentity(at: fixture.destination), originalIdentity)
        XCTAssertTrue(recorder.calls.contains(.cleanupTemporary))
        try assertNoWriteArtifacts(for: fixture)
        try assertFixtureSentinel(fixture)
    }

    func testPrecommitFailureWithTemporaryUnlinkFailureReportsRetainedArtifact() throws {
        let fixture = try makeWriteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let originalIdentity = try XCTUnwrap(fixture.originalIdentity)
        let recorder = WorkspaceInjectedCallRecorder(failures: [
            .renameSwap: .unreadable,
            .cleanupTemporary: .cleanupFailed,
        ])

        let outcome = write(
            to: fixture,
            expecting: .existing(originalIdentity),
            hooks: recorder.hooks()
        )

        let result = try XCTUnwrap(requireNotCommitted(outcome, reason: .unreadable))
        guard case let .retained(artifact) = result.artifactState else {
            return XCTFail("Expected retained temporary file, got \(result.artifactState)")
        }
        XCTAssertEqual(try writeText(at: fixture.destination), "original")
        XCTAssertEqual(try writeFileIdentity(at: fixture.destination), originalIdentity)
        XCTAssertEqual(try writeText(at: artifact.fileURL), "replacement bytes")
        XCTAssertEqual(
            try writeTemporaryURLs(in: fixture.destination.deletingLastPathComponent())
                .map(\.lastPathComponent),
            [artifact.fileURL.lastPathComponent]
        )
        try assertFixtureSentinel(fixture)
    }
}
