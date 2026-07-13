import Foundation
@testable import WorkspaceKit
import XCTest

extension WorkspaceAnchoredFileSystemTests {
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
}
