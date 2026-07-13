import Foundation
@testable import WorkspaceKit
import XCTest

extension WorkspaceAnchoredFileSystemTests {
    func testTemporaryCleanupDoesNotDeleteRacingReplacement() throws {
        let fixture = try makeWriteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let originalIdentity = try XCTUnwrap(fixture.originalIdentity)
        let directory = fixture.destination.deletingLastPathComponent()
        let savedPrepared = directory.appendingPathComponent("saved-prepared.md")
        let mutation = SynchronousMutation {
            let temporary = try self.onlyArtifact(in: directory, cleanup: false)
            try FileManager.default.moveItem(at: temporary, to: savedPrepared)
            try "temporary racer".write(to: temporary, atomically: false, encoding: .utf8)
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
        let result = try XCTUnwrap(requireNotCommitted(outcome, reason: .unreadable))
        guard case .removalIndeterminate = result.artifactState else {
            return XCTFail("Expected identity-conflict cleanup state")
        }
        XCTAssertEqual(try writeText(at: savedPrepared), "replacement bytes")
        XCTAssertEqual(
            try writeText(at: onlyArtifact(in: directory, cleanup: false)),
            "temporary racer"
        )
        XCTAssertEqual(try writeText(at: fixture.destination), "original")
    }

    func testRollbackArtifactCleanupDoesNotDeleteRacingReplacement() throws {
        let fixture = try makeWriteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let originalIdentity = try XCTUnwrap(fixture.originalIdentity)
        let directory = fixture.destination.deletingLastPathComponent()
        let savedOriginal = directory.appendingPathComponent("saved-original.md")
        let mutation = SynchronousMutation {
            let rollbackArtifact = try self.onlyArtifact(in: directory, cleanup: false)
            try FileManager.default.moveItem(at: rollbackArtifact, to: savedOriginal)
            try "rollback racer".write(
                to: rollbackArtifact,
                atomically: false,
                encoding: .utf8
            )
        }
        let hooks = WorkspaceAnchoredFileSystem.Hooks(injectedFailure: { call in
            if call == .unlinkRollbackArtifact { mutation.run() }
            return nil
        })

        let outcome = write(
            to: fixture,
            expecting: .existing(originalIdentity),
            hooks: hooks
        )

        try mutation.rethrowIfFailed()
        let durable = try XCTUnwrap(requireDurable(outcome))
        guard case .removalIndeterminate = durable.cleanupState else {
            return XCTFail("Expected identity-conflict cleanup state")
        }
        XCTAssertEqual(try writeText(at: fixture.destination), "replacement bytes")
        XCTAssertEqual(try writeText(at: savedOriginal), "original")
        XCTAssertEqual(
            try writeText(at: onlyArtifact(in: directory, cleanup: false)),
            "rollback racer"
        )
    }

    func testCreatedDestinationRollbackDoesNotDeleteRacingReplacement() throws {
        let fixture = try makeWriteFixture(originalText: nil)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let directory = fixture.destination.deletingLastPathComponent()
        let savedPrepared = directory.appendingPathComponent("saved-created.md")
        let mutation = SynchronousMutation {
            try FileManager.default.moveItem(at: fixture.destination, to: savedPrepared)
            try "destination racer".write(
                to: fixture.destination,
                atomically: false,
                encoding: .utf8
            )
        }
        let hooks = WorkspaceAnchoredFileSystem.Hooks(injectedFailure: { call in
            switch call {
            case .afterRenameExclusive:
                return .unreadable
            case .unlinkCreatedDestination:
                mutation.run()
                return nil
            default:
                return nil
            }
        })

        let outcome = write(to: fixture, expecting: .missing, hooks: hooks)

        try mutation.rethrowIfFailed()
        guard case let .committedButIndeterminate(result) = outcome else {
            return XCTFail("Expected committedButIndeterminate, got \(outcome)")
        }
        guard case .removalIndeterminate = result.recoveryArtifact else {
            return XCTFail("Expected identity-conflict cleanup state")
        }
        XCTAssertEqual(try writeText(at: fixture.destination), "destination racer")
        XCTAssertEqual(try writeText(at: savedPrepared), "replacement bytes")
    }

    func testQuarantineUnlinkRevalidationPreservesRacerAndPreparedBytes() throws {
        let fixture = try makeWriteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let originalIdentity = try XCTUnwrap(fixture.originalIdentity)
        let directory = fixture.destination.deletingLastPathComponent()
        let savedPrepared = directory.appendingPathComponent("saved-from-quarantine.md")
        let mutation = SynchronousMutation {
            let quarantine = try self.onlyArtifact(in: directory, cleanup: true)
            try FileManager.default.moveItem(at: quarantine, to: savedPrepared)
            try "quarantine racer".write(
                to: quarantine,
                atomically: false,
                encoding: .utf8
            )
        }
        let hooks = WorkspaceAnchoredFileSystem.Hooks(injectedFailure: { call in
            switch call {
            case .renameSwap:
                return .unreadable
            case .unlinkQuarantinedArtifact:
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
        let result = try XCTUnwrap(requireNotCommitted(outcome, reason: .unreadable))
        guard case .removalIndeterminate = result.artifactState else {
            return XCTFail("Expected quarantine identity-conflict state")
        }
        XCTAssertEqual(try writeText(at: savedPrepared), "replacement bytes")
        XCTAssertEqual(
            try writeText(at: onlyArtifact(in: directory, cleanup: false)),
            "quarantine racer"
        )
        XCTAssertTrue(try writeCleanupURLs(in: directory).isEmpty)
    }

    func testQuarantineRestoreNeverReplacesRacingDestination() throws {
        let fixture = try makeWriteFixture(originalText: nil)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let directory = fixture.destination.deletingLastPathComponent()
        let savedPrepared = directory.appendingPathComponent("saved-restore-prepared.md")
        let quarantineMutation = SynchronousMutation {
            let quarantine = try self.onlyArtifact(in: directory, cleanup: true)
            try FileManager.default.moveItem(at: quarantine, to: savedPrepared)
            try "quarantine racer".write(
                to: quarantine,
                atomically: false,
                encoding: .utf8
            )
        }
        let destinationMutation = SynchronousMutation {
            try "restore-boundary racer".write(
                to: fixture.destination,
                atomically: false,
                encoding: .utf8
            )
        }
        let hooks = WorkspaceAnchoredFileSystem.Hooks(injectedFailure: { call in
            switch call {
            case .afterRenameExclusive:
                return .unreadable
            case .unlinkQuarantinedArtifact:
                quarantineMutation.run()
                return nil
            case .restoreQuarantinedArtifact:
                destinationMutation.run()
                return nil
            default:
                return nil
            }
        })

        let outcome = write(to: fixture, expecting: .missing, hooks: hooks)

        try quarantineMutation.rethrowIfFailed()
        try destinationMutation.rethrowIfFailed()
        guard case let .committedButIndeterminate(result) = outcome else {
            return XCTFail("Expected committedButIndeterminate, got \(outcome)")
        }
        guard case .removalIndeterminate = result.recoveryArtifact else {
            return XCTFail("Expected quarantine restore conflict state")
        }
        XCTAssertEqual(try writeText(at: fixture.destination), "restore-boundary racer")
        XCTAssertEqual(try writeText(at: savedPrepared), "replacement bytes")
        XCTAssertEqual(
            try writeText(at: onlyArtifact(in: directory, cleanup: true)),
            "quarantine racer"
        )
    }

    private func onlyArtifact(in directory: URL, cleanup: Bool) throws -> URL {
        let urls = try cleanup
            ? writeCleanupURLs(in: directory)
            : writeTemporaryURLs(in: directory)
        guard urls.count == 1, let url = urls.first else {
            throw WorkspaceCleanupTestError.unexpectedArtifactCount(urls.count)
        }
        return url
    }
}

private enum WorkspaceCleanupTestError: Error {
    case unexpectedArtifactCount(Int)
}
