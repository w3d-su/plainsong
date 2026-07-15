import Darwin
import Foundation
@testable import WorkspaceKit
import XCTest

extension WorkspaceAnchoredFileSystemTests {
    func testExistingReplacementCommitsNewIdentityAndRemovesRollbackMaterial() throws {
        let fixture = try makeWriteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let originalIdentity = try XCTUnwrap(fixture.originalIdentity)

        let outcome = write(to: fixture, expecting: .existing(originalIdentity))

        let durable = try XCTUnwrap(requireDurable(outcome))
        XCTAssertEqual(durable.cleanupState, .none)
        XCTAssertEqual(try writeText(at: fixture.destination), "replacement bytes")
        XCTAssertEqual(
            durable.metadata,
            try WorkspaceAnchoredFileSystem.validate(fixture.location)
        )
        XCTAssertNotEqual(durable.metadata.identity, originalIdentity)
        try assertNoWriteArtifacts(for: fixture)
        try assertFixtureSentinel(fixture)
    }

    func testMissingCreateUsesExclusiveCommitAndPublishesPreparedIdentity() throws {
        let fixture = try makeWriteFixture(originalText: nil)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }

        let outcome = write(to: fixture, expecting: .missing)

        let durable = try XCTUnwrap(requireDurable(outcome))
        XCTAssertEqual(durable.cleanupState, .none)
        XCTAssertEqual(try writeText(at: fixture.destination), "replacement bytes")
        XCTAssertEqual(
            durable.metadata,
            try WorkspaceAnchoredFileSystem.validate(fixture.location)
        )
        try assertNoWriteArtifacts(for: fixture)
        try assertFixtureSentinel(fixture)
    }

    func testFailureAfterSwapRestoresOriginalIdentityAndDurablyRemovesPreparedFile() throws {
        let fixture = try makeWriteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let originalIdentity = try XCTUnwrap(fixture.originalIdentity)
        let recorder = WorkspaceInjectedCallRecorder(
            failures: [.afterRenameSwap: .unreadable]
        )

        let outcome = write(
            to: fixture,
            expecting: .existing(originalIdentity),
            hooks: recorder.hooks()
        )

        let result = try XCTUnwrap(requireNotCommitted(outcome, reason: .unreadable))
        XCTAssertEqual(result.artifactState, .none)
        XCTAssertEqual(try writeText(at: fixture.destination), "original")
        XCTAssertEqual(try writeFileIdentity(at: fixture.destination), originalIdentity)
        XCTAssertTrue(recorder.calls.contains(.renameRollback))
        XCTAssertTrue(recorder.calls.contains(.syncRollbackDirectory))
        try assertNoWriteArtifacts(for: fixture)
        try assertFixtureSentinel(fixture)
    }

    func testRollbackCleanupSupportsWriteOnlyDestinationMode() throws {
        let fixture = try makeWriteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let originalIdentity = try XCTUnwrap(fixture.originalIdentity)
        XCTAssertEqual(Darwin.chmod(fixture.destination.path, mode_t(S_IWUSR)), 0)
        defer { _ = Darwin.chmod(fixture.destination.path, mode_t(S_IRUSR | S_IWUSR)) }
        let modeInspection = temporaryModeInspection(
            for: fixture,
            expectedMode: mode_t(S_IWUSR)
        )
        let hooks = rollbackFailureHooks(modeInspection: modeInspection)

        let outcome = write(
            to: fixture,
            expecting: .existing(originalIdentity),
            hooks: hooks
        )

        try modeInspection.rethrowIfFailed()
        let result = try XCTUnwrap(requireNotCommitted(outcome, reason: .unreadable))
        XCTAssertEqual(result.artifactState, .none)
        XCTAssertEqual(try writeFileIdentity(at: fixture.destination), originalIdentity)
        try assertNoWriteArtifacts(for: fixture)
        try assertFixtureSentinel(fixture)
    }

    func testRollbackCleanupSupportsNoAccessDestinationMode() throws {
        let fixture = try makeWriteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let originalIdentity = try XCTUnwrap(fixture.originalIdentity)
        XCTAssertEqual(Darwin.chmod(fixture.destination.path, mode_t(0)), 0)
        defer { _ = Darwin.chmod(fixture.destination.path, mode_t(S_IRUSR | S_IWUSR)) }
        let modeInspection = temporaryModeInspection(for: fixture, expectedMode: mode_t(0))
        let hooks = rollbackFailureHooks(modeInspection: modeInspection)

        let outcome = write(
            to: fixture,
            expecting: .existing(originalIdentity),
            hooks: hooks
        )

        try modeInspection.rethrowIfFailed()
        let result = try XCTUnwrap(requireNotCommitted(outcome, reason: .unreadable))
        XCTAssertEqual(result.artifactState, .none)
        XCTAssertEqual(try writeFileIdentity(at: fixture.destination), originalIdentity)
        try assertNoWriteArtifacts(for: fixture)
        try assertFixtureSentinel(fixture)
    }

    func testCleanupInspectionErrorCannotCollapseToNoArtifact() throws {
        let fixture = try makeWriteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let originalIdentity = try XCTUnwrap(fixture.originalIdentity)
        let directory = fixture.destination.deletingLastPathComponent()
        let originalMode = try mode_t(noFollowStatus(at: directory).st_mode & mode_t(0o7777))
        defer { _ = Darwin.chmod(directory.path, originalMode) }
        let permissionMutation = SynchronousMutation {
            guard Darwin.chmod(directory.path, mode_t(0)) == 0 else {
                throw WorkspaceWriteModeTestError.permissionChangeFailed
            }
        }
        let hooks = WorkspaceAnchoredFileSystem.Hooks(injectedFailure: { call in
            switch call {
            case .renameSwap:
                return .unreadable
            case .syncCleanupDirectory:
                permissionMutation.run()
                return nil
            default:
                return nil
            }
        })

        let outcome = write(
            to: fixture,
            expecting: .existing(originalIdentity),
            hooks: hooks
        )

        XCTAssertEqual(Darwin.chmod(directory.path, originalMode), 0)
        try permissionMutation.rethrowIfFailed()
        let result = try XCTUnwrap(requireIndeterminate(outcome, reason: .unreadable))
        guard case .removalIndeterminate = result.recoveryArtifact else {
            return XCTFail("Inspection failure must not report no cleanup artifact")
        }
        XCTAssertEqual(try writeFileIdentity(at: fixture.destination), originalIdentity)
        try assertFixtureSentinel(fixture)
    }

    private func temporaryModeInspection(
        for fixture: WorkspaceWriteFixture,
        expectedMode: mode_t
    ) -> SynchronousMutation {
        SynchronousMutation {
            let directory = fixture.destination.deletingLastPathComponent()
            let temporaryURLs = try self.writeTemporaryURLs(in: directory)
            guard temporaryURLs.count == 1, let temporary = temporaryURLs.first else {
                throw WorkspaceWriteModeTestError.unexpectedArtifactCount(temporaryURLs.count)
            }
            let status = try self.noFollowStatus(at: temporary)
            guard mode_t(status.st_mode & mode_t(0o7777)) == expectedMode else {
                throw WorkspaceWriteModeTestError.unexpectedMode(status.st_mode)
            }
        }
    }

    private func rollbackFailureHooks(
        modeInspection: SynchronousMutation
    ) -> WorkspaceAnchoredFileSystem.Hooks {
        WorkspaceAnchoredFileSystem.Hooks(injectedFailure: { call in
            switch call {
            case .afterRenameSwap:
                return .unreadable
            case .cleanupTemporary:
                modeInspection.run()
                return nil
            default:
                return nil
            }
        })
    }

    func testFailureAfterExclusiveRenameRemovesCreatedDestinationAndSyncsRollback() throws {
        let fixture = try makeWriteFixture(originalText: nil)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let recorder = WorkspaceInjectedCallRecorder(
            failures: [.afterRenameExclusive: .unreadable]
        )

        let outcome = write(to: fixture, expecting: .missing, hooks: recorder.hooks())

        let result = try XCTUnwrap(requireNotCommitted(outcome, reason: .unreadable))
        XCTAssertEqual(result.artifactState, .none)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertTrue(recorder.calls.contains(.unlinkCreatedDestination))
        XCTAssertTrue(recorder.calls.contains(.syncRollbackDirectory))
        try assertNoWriteArtifacts(for: fixture)
        try assertFixtureSentinel(fixture)
    }

    func testExclusiveCommitCollisionCannotProveDestinationMissing() throws {
        let fixture = try makeWriteFixture(originalText: nil)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let mutation = SynchronousMutation {
            try "racing destination".write(
                to: fixture.destination,
                atomically: true,
                encoding: .utf8
            )
        }
        let hooks = WorkspaceAnchoredFileSystem.Hooks { event in
            if event == .willCommit(.exclusiveCreate) { mutation.run() }
        }

        let outcome = write(to: fixture, expecting: .missing, hooks: hooks)

        try mutation.rethrowIfFailed()
        let result = try XCTUnwrap(requireIndeterminate(outcome, reason: .changedIdentity))
        XCTAssertNotNil(result.preparedMetadata)
        XCTAssertEqual(result.recoveryArtifact, .none)
        XCTAssertEqual(try writeText(at: fixture.destination), "racing destination")
        try assertNoWriteArtifacts(for: fixture)
        try assertFixtureSentinel(fixture)
    }

    func testDisplacedMetadataFailureReportsIndeterminateAndRetainsOriginalArtifact() throws {
        let fixture = try makeWriteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let originalIdentity = try XCTUnwrap(fixture.originalIdentity)
        let recorder = WorkspaceInjectedCallRecorder(
            failures: [.captureDisplacedEntry: .unreadable]
        )

        let outcome = write(
            to: fixture,
            expecting: .existing(originalIdentity),
            hooks: recorder.hooks()
        )

        let result = try XCTUnwrap(requireIndeterminate(outcome, reason: .unreadable))
        let preparedMetadata = try XCTUnwrap(result.preparedMetadata)
        guard case let .retained(artifact) = result.recoveryArtifact else {
            return XCTFail("Expected retained rollback material, got \(result.recoveryArtifact)")
        }
        XCTAssertEqual(try writeText(at: fixture.destination), "replacement bytes")
        XCTAssertEqual(try writeFileIdentity(at: fixture.destination), preparedMetadata.identity)
        XCTAssertEqual(try writeText(at: artifact.fileURL), "original")
        XCTAssertEqual(try writeFileIdentity(at: artifact.fileURL), originalIdentity)
        XCTAssertEqual(
            try writeTemporaryURLs(in: fixture.destination.deletingLastPathComponent())
                .map(\.lastPathComponent),
            [artifact.fileURL.lastPathComponent]
        )
        try assertFixtureSentinel(fixture)
    }

    func testRollbackArtifactUnlinkFailureReturnsDurableCommitWithRetainedOriginal() throws {
        let fixture = try makeWriteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let originalIdentity = try XCTUnwrap(fixture.originalIdentity)
        let recorder = WorkspaceInjectedCallRecorder(
            failures: [.unlinkRollbackArtifact: .cleanupFailed]
        )

        let outcome = write(
            to: fixture,
            expecting: .existing(originalIdentity),
            hooks: recorder.hooks()
        )

        let durable = try XCTUnwrap(requireDurable(outcome))
        guard case let .retained(artifact) = durable.cleanupState else {
            return XCTFail("Expected retained cleanup artifact, got \(durable.cleanupState)")
        }
        XCTAssertEqual(try writeText(at: fixture.destination), "replacement bytes")
        XCTAssertEqual(try writeFileIdentity(at: fixture.destination), durable.metadata.identity)
        XCTAssertEqual(try writeText(at: artifact.fileURL), "original")
        XCTAssertEqual(try writeFileIdentity(at: artifact.fileURL), originalIdentity)
        XCTAssertEqual(
            try writeTemporaryURLs(in: fixture.destination.deletingLastPathComponent())
                .map(\.lastPathComponent),
            [artifact.fileURL.lastPathComponent]
        )
        try assertFixtureSentinel(fixture)
    }

    func testCleanupDirectorySyncFailureReturnsDurableCommitWithIndeterminateRemoval() throws {
        let fixture = try makeWriteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let originalIdentity = try XCTUnwrap(fixture.originalIdentity)
        let recorder = WorkspaceInjectedCallRecorder(
            failures: [.syncCleanupDirectory: .durabilityFailed]
        )

        let outcome = write(
            to: fixture,
            expecting: .existing(originalIdentity),
            hooks: recorder.hooks()
        )

        let durable = try XCTUnwrap(requireDurable(outcome))
        guard case let .removalIndeterminate(artifact) = durable.cleanupState else {
            return XCTFail("Expected indeterminate cleanup removal, got \(durable.cleanupState)")
        }
        XCTAssertEqual(try writeText(at: fixture.destination), "replacement bytes")
        XCTAssertEqual(try writeFileIdentity(at: fixture.destination), durable.metadata.identity)
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.fileURL.path))
        try assertNoWriteArtifacts(for: fixture)
        try assertFixtureSentinel(fixture)
    }
}

private enum WorkspaceWriteModeTestError: Error {
    case permissionChangeFailed
    case unexpectedArtifactCount(Int)
    case unexpectedMode(mode_t)
}
