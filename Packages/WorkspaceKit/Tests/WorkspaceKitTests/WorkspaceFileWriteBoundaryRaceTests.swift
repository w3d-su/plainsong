import Foundation
@testable import WorkspaceKit
import XCTest

extension WorkspaceAnchoredFileSystemTests {
    func testTemporaryPreparationCleanupPublishingPreparedFileCannotReportNotCommitted() async throws {
        let fixture = try makeWriteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let originalIdentity = try XCTUnwrap(fixture.originalIdentity)
        let directory = fixture.destination.deletingLastPathComponent()
        let savedOriginal = directory.appendingPathComponent("saved-preparation-original.md")
        let mutation = SynchronousMutation {
            let prepared = try self.onlyArtifact(in: directory, cleanup: false)
            try FileManager.default.moveItem(at: fixture.destination, to: savedOriginal)
            try FileManager.default.moveItem(at: prepared, to: fixture.destination)
        }
        let hooks = WorkspaceAnchoredFileSystem.Hooks(
            eventHandler: { event in
                if event == .temporaryFileCreated {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            },
            injectedFailure: { call in
                if call == .cleanupTemporary { mutation.run() }
                return nil
            }
        )
        let location = fixture.location

        let outcome = await Task.detached {
            WorkspaceNoFollowFileWriter.write(
                Data("replacement bytes".utf8),
                to: location,
                expecting: .existing(originalIdentity),
                hooks: hooks
            )
        }.value

        try mutation.rethrowIfFailed()
        let result = try XCTUnwrap(requireIndeterminate(outcome, reason: .changedIdentity))
        XCTAssertNil(result.preparedMetadata)
        XCTAssertEqual(result.recoveryArtifact, .retained(fixture.location))
        XCTAssertEqual(try writeText(at: fixture.destination), "")
        XCTAssertEqual(try writeFileIdentity(at: savedOriginal), originalIdentity)
        try assertFixtureSentinel(fixture)
    }

    func testPreparedValidationCleanupPublishingPreparedFileCannotReportNotCommitted() async throws {
        let fixture = try makeWriteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let originalIdentity = try XCTUnwrap(fixture.originalIdentity)
        let directory = fixture.destination.deletingLastPathComponent()
        let savedOriginal = directory.appendingPathComponent("saved-validation-original.md")
        let mutation = SynchronousMutation {
            let prepared = try self.onlyArtifact(in: directory, cleanup: false)
            try FileManager.default.moveItem(at: fixture.destination, to: savedOriginal)
            try FileManager.default.moveItem(at: prepared, to: fixture.destination)
        }
        let hooks = WorkspaceAnchoredFileSystem.Hooks(
            eventHandler: { event in
                if event == .temporaryFilePrepared {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            },
            injectedFailure: { call in
                if call == .cleanupTemporary { mutation.run() }
                return nil
            }
        )
        let location = fixture.location

        let outcome = await Task.detached {
            WorkspaceNoFollowFileWriter.write(
                Data("replacement bytes".utf8),
                to: location,
                expecting: .existing(originalIdentity),
                hooks: hooks
            )
        }.value

        try mutation.rethrowIfFailed()
        let result = try XCTUnwrap(requireIndeterminate(outcome, reason: .changedIdentity))
        let preparedMetadata = try XCTUnwrap(result.preparedMetadata)
        XCTAssertEqual(result.recoveryArtifact, .retained(fixture.location))
        XCTAssertEqual(try writeFileIdentity(at: fixture.destination), preparedMetadata.identity)
        XCTAssertEqual(try writeText(at: fixture.destination), "replacement bytes")
        XCTAssertEqual(try writeFileIdentity(at: savedOriginal), originalIdentity)
        try assertFixtureSentinel(fixture)
    }

    func testAfterRenameSwapFailureNeverRollsBackThroughDisplacedRacer() throws {
        let fixture = try makeWriteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let originalIdentity = try XCTUnwrap(fixture.originalIdentity)
        let directory = fixture.destination.deletingLastPathComponent()
        let savedOriginal = directory.appendingPathComponent("saved-after-rename-original.md")
        let mutation = SynchronousMutation {
            let displaced = try self.onlyArtifact(in: directory, cleanup: false)
            try FileManager.default.moveItem(at: displaced, to: savedOriginal)
            try "after-rename racer".write(
                to: displaced,
                atomically: false,
                encoding: .utf8
            )
        }
        let hooks = WorkspaceAnchoredFileSystem.Hooks(
            eventHandler: { event in
                if event == .didCommit(.swap) { mutation.run() }
            },
            injectedFailure: { call in
                call == .afterRenameSwap ? .unreadable : nil
            }
        )

        let outcome = write(
            to: fixture,
            expecting: .existing(originalIdentity),
            hooks: hooks
        )

        try mutation.rethrowIfFailed()
        let result = try XCTUnwrap(requireIndeterminate(outcome, reason: .unreadable))
        guard case .removalIndeterminate = result.recoveryArtifact else {
            return XCTFail("Expected indeterminate displaced-racer state")
        }
        let preparedMetadata = try XCTUnwrap(result.preparedMetadata)
        XCTAssertEqual(try writeText(at: fixture.destination), "replacement bytes")
        XCTAssertEqual(try writeFileIdentity(at: fixture.destination), preparedMetadata.identity)
        XCTAssertEqual(try writeText(at: savedOriginal), "original")
        XCTAssertEqual(try writeFileIdentity(at: savedOriginal), originalIdentity)
        XCTAssertEqual(
            try writeText(at: onlyArtifact(in: directory, cleanup: false)),
            "after-rename racer"
        )
        try assertFixtureSentinel(fixture)
    }

    func testRollbackFinalValidationBoundaryFailsClosedOnDisplacedRacer() throws {
        let fixture = try makeWriteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let originalIdentity = try XCTUnwrap(fixture.originalIdentity)
        let directory = fixture.destination.deletingLastPathComponent()
        let savedOriginal = directory.appendingPathComponent("saved-rollback-boundary-original.md")
        let mutation = SynchronousMutation {
            let displaced = try self.onlyArtifact(in: directory, cleanup: false)
            try FileManager.default.moveItem(at: displaced, to: savedOriginal)
            try "rollback-boundary racer".write(
                to: displaced,
                atomically: false,
                encoding: .utf8
            )
        }
        let hooks = WorkspaceAnchoredFileSystem.Hooks(injectedFailure: { call in
            switch call {
            case .validateCommittedLeaf:
                return .durabilityFailed
            case .renameRollbackAfterValidation:
                mutation.run()
                return .namespaceChanged
            default:
                return nil
            }
        })

        let outcome = write(
            to: fixture,
            expecting: .existing(originalIdentity),
            hooks: hooks
        )

        try mutation.rethrowIfFailed()
        let result = try XCTUnwrap(requireIndeterminate(outcome, reason: .namespaceChanged))
        guard case .removalIndeterminate = result.recoveryArtifact else {
            return XCTFail("Expected indeterminate rollback-boundary state")
        }
        let preparedMetadata = try XCTUnwrap(result.preparedMetadata)
        XCTAssertEqual(try writeText(at: fixture.destination), "replacement bytes")
        XCTAssertEqual(try writeFileIdentity(at: fixture.destination), preparedMetadata.identity)
        XCTAssertEqual(try writeText(at: savedOriginal), "original")
        XCTAssertEqual(try writeFileIdentity(at: savedOriginal), originalIdentity)
        XCTAssertEqual(
            try writeText(at: onlyArtifact(in: directory, cleanup: false)),
            "rollback-boundary racer"
        )
        try assertFixtureSentinel(fixture)
    }

    func testFinalValidationToQuarantineRenameBoundaryFailsClosedOnRacer() throws {
        let fixture = try makeWriteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let originalIdentity = try XCTUnwrap(fixture.originalIdentity)
        let directory = fixture.destination.deletingLastPathComponent()
        let savedPrepared = directory.appendingPathComponent("saved-quarantine-rename.md")
        let mutation = SynchronousMutation {
            let temporary = try self.onlyArtifact(in: directory, cleanup: false)
            try FileManager.default.moveItem(at: temporary, to: savedPrepared)
            try "quarantine-rename racer".write(
                to: temporary,
                atomically: false,
                encoding: .utf8
            )
        }
        let hooks = WorkspaceAnchoredFileSystem.Hooks(injectedFailure: { call in
            switch call {
            case .renameSwap:
                return .unreadable
            case .renameQuarantinedArtifactAfterValidation:
                mutation.run()
                return .namespaceChanged
            default:
                return nil
            }
        })

        let outcome = write(
            to: fixture,
            expecting: .existing(originalIdentity),
            hooks: hooks
        )

        try mutation.rethrowIfFailed()
        let result = try XCTUnwrap(requireNotCommitted(outcome, reason: .unreadable))
        guard case .removalIndeterminate = result.artifactState else {
            return XCTFail("Expected indeterminate quarantine-rename state")
        }
        XCTAssertEqual(try writeText(at: savedPrepared), "replacement bytes")
        XCTAssertEqual(
            try writeText(at: onlyArtifact(in: directory, cleanup: false)),
            "quarantine-rename racer"
        )
        XCTAssertTrue(try writeCleanupURLs(in: directory).isEmpty)
        XCTAssertEqual(try writeText(at: fixture.destination), "original")
        XCTAssertEqual(try writeFileIdentity(at: fixture.destination), originalIdentity)
        try assertFixtureSentinel(fixture)
    }

    func testExistingPrecommitCleanupPublishingPreparedFileCannotReportNotCommitted() throws {
        let fixture = try makeWriteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let originalIdentity = try XCTUnwrap(fixture.originalIdentity)
        let directory = fixture.destination.deletingLastPathComponent()
        let savedOriginal = directory.appendingPathComponent("saved-precommit-original.md")
        let mutation = SynchronousMutation {
            let prepared = try self.onlyArtifact(in: directory, cleanup: false)
            try FileManager.default.moveItem(at: fixture.destination, to: savedOriginal)
            try FileManager.default.moveItem(at: prepared, to: fixture.destination)
        }
        let hooks = WorkspaceAnchoredFileSystem.Hooks(injectedFailure: { call in
            switch call {
            case .renameSwap:
                return .unreadable
            case .cleanupTemporary:
                mutation.run()
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

        try mutation.rethrowIfFailed()
        let result = try XCTUnwrap(requireIndeterminate(outcome, reason: .changedIdentity))
        let preparedMetadata = try XCTUnwrap(result.preparedMetadata)
        XCTAssertEqual(result.recoveryArtifact, .retained(fixture.location))
        XCTAssertEqual(try writeFileIdentity(at: fixture.destination), preparedMetadata.identity)
        XCTAssertEqual(try writeText(at: fixture.destination), "replacement bytes")
        XCTAssertEqual(try writeFileIdentity(at: savedOriginal), originalIdentity)
        try assertFixtureSentinel(fixture)
    }

    func testExistingRollbackCleanupPublishingPreparedFileCannotReportNotCommitted() throws {
        let fixture = try makeWriteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let originalIdentity = try XCTUnwrap(fixture.originalIdentity)
        let directory = fixture.destination.deletingLastPathComponent()
        let savedOriginal = directory.appendingPathComponent("saved-restored-original.md")
        let mutation = SynchronousMutation {
            let prepared = try self.onlyArtifact(in: directory, cleanup: false)
            try FileManager.default.moveItem(at: fixture.destination, to: savedOriginal)
            try FileManager.default.moveItem(at: prepared, to: fixture.destination)
        }
        let hooks = WorkspaceAnchoredFileSystem.Hooks(injectedFailure: { call in
            switch call {
            case .afterRenameSwap:
                return .unreadable
            case .cleanupTemporary:
                mutation.run()
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

        try mutation.rethrowIfFailed()
        let result = try XCTUnwrap(requireIndeterminate(outcome, reason: .changedIdentity))
        let preparedMetadata = try XCTUnwrap(result.preparedMetadata)
        XCTAssertEqual(result.recoveryArtifact, .retained(fixture.location))
        XCTAssertEqual(try writeFileIdentity(at: fixture.destination), preparedMetadata.identity)
        XCTAssertEqual(try writeText(at: fixture.destination), "replacement bytes")
        XCTAssertEqual(try writeFileIdentity(at: savedOriginal), originalIdentity)
        try assertFixtureSentinel(fixture)
    }

    func testMissingPrecommitCleanupPublishingPreparedFileCannotReportNotCommitted() throws {
        let fixture = try makeWriteFixture(originalText: nil)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let directory = fixture.destination.deletingLastPathComponent()
        let mutation = SynchronousMutation {
            let prepared = try self.onlyArtifact(in: directory, cleanup: false)
            try FileManager.default.moveItem(at: prepared, to: fixture.destination)
        }
        let hooks = WorkspaceAnchoredFileSystem.Hooks(injectedFailure: { call in
            switch call {
            case .renameExclusive:
                return .unreadable
            case .cleanupTemporary:
                mutation.run()
                return nil
            default:
                return nil
            }
        })

        let outcome = write(to: fixture, expecting: .missing, hooks: hooks)

        try mutation.rethrowIfFailed()
        let result = try XCTUnwrap(requireIndeterminate(outcome, reason: .changedIdentity))
        let preparedMetadata = try XCTUnwrap(result.preparedMetadata)
        XCTAssertEqual(result.recoveryArtifact, .retained(fixture.location))
        XCTAssertEqual(try writeFileIdentity(at: fixture.destination), preparedMetadata.identity)
        XCTAssertEqual(try writeText(at: fixture.destination), "replacement bytes")
        try assertFixtureSentinel(fixture)
    }

    func testMissingRollbackFinalCleanupHookMustStillProveDestinationMissing() throws {
        let fixture = try makeWriteFixture(originalText: nil)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let mutation = SynchronousMutation {
            try "cleanup racer".write(
                to: fixture.destination,
                atomically: false,
                encoding: .utf8
            )
        }
        let hooks = WorkspaceAnchoredFileSystem.Hooks(injectedFailure: { call in
            switch call {
            case .afterRenameExclusive:
                return .unreadable
            case .syncRollbackDirectory:
                mutation.run()
                return nil
            default:
                return nil
            }
        })

        let outcome = write(to: fixture, expecting: .missing, hooks: hooks)

        try mutation.rethrowIfFailed()
        let result = try XCTUnwrap(requireIndeterminate(outcome, reason: .changedIdentity))
        XCTAssertNotNil(result.preparedMetadata)
        XCTAssertEqual(result.recoveryArtifact, .none)
        XCTAssertEqual(try writeText(at: fixture.destination), "cleanup racer")
        try assertFixtureSentinel(fixture)
    }
}
