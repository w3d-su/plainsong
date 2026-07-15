import Darwin
import Foundation
@testable import WorkspaceKit
import XCTest

extension WorkspaceAnchoredFileSystemTests {
    func testTemporaryCreationRaceIsTruncatedAndDurableBytesStayExact() throws {
        let fixture = try makeWriteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let originalIdentity = try XCTUnwrap(fixture.originalIdentity)
        let expected = Data("replacement bytes".utf8)
        let mutation = SynchronousMutation {
            let temporary = try self.onlyWriteTemporaryURL(for: fixture)
            let status = try self.noFollowStatus(at: temporary)
            guard status.st_mode & mode_t(0o777) == mode_t(0o600) else {
                throw WorkspaceWriteTestError.unexpectedPermissions
            }
            try self.overwriteInPlace(
                Data("racing payload with a tail that must disappear".utf8),
                at: temporary
            )
        }
        let hooks = WorkspaceAnchoredFileSystem.Hooks(eventHandler: { event in
            if event == .temporaryFileCreated { mutation.run() }
        })

        let outcome = WorkspaceNoFollowFileWriter.write(
            expected,
            to: fixture.location,
            expecting: .existing(originalIdentity),
            hooks: hooks
        )

        try mutation.rethrowIfFailed()
        let durable = try XCTUnwrap(requireDurable(outcome))
        XCTAssertEqual(try Data(contentsOf: fixture.destination), expected)
        XCTAssertEqual(durable.metadata.byteCount, Int64(expected.count))
    }

    func testSameSizeMutationAfterTemporaryPreparationCannotCommit() throws {
        try assertPreparedMutationCannotCommit(
            Data("XXXXXXXXXXXXXXXXX".utf8),
            at: .temporaryFilePrepared
        )
    }

    func testLongerMutationAfterTemporaryPreparationCannotCommit() throws {
        try assertPreparedMutationCannotCommit(
            Data("replacement bytes plus a racing tail".utf8),
            at: .temporaryFilePrepared
        )
    }

    func testMutationImmediatelyBeforeRenameCannotCommit() throws {
        try assertPreparedMutationCannotCommit(
            Data("replacement bytes plus precommit corruption".utf8),
            at: .willCommit(.swap)
        )
    }

    func testMutationAfterRenameRollsBackInsteadOfReportingDurable() throws {
        let fixture = try makeWriteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let originalIdentity = try XCTUnwrap(fixture.originalIdentity)
        let mutation = SynchronousMutation {
            try self.overwriteInPlace(
                Data("corrupted committed bytes".utf8),
                at: fixture.destination
            )
        }
        let hooks = WorkspaceAnchoredFileSystem.Hooks(eventHandler: { event in
            if event == .didCommit(.swap) { mutation.run() }
        })

        let outcome = write(
            to: fixture,
            expecting: .existing(originalIdentity),
            hooks: hooks
        )

        try mutation.rethrowIfFailed()
        let result = try XCTUnwrap(requireNotCommitted(outcome, reason: .changedContent))
        XCTAssertEqual(result.artifactState, .none)
        XCTAssertEqual(try writeText(at: fixture.destination), "original")
        XCTAssertEqual(try writeFileIdentity(at: fixture.destination), originalIdentity)
        try assertNoWriteArtifacts(for: fixture)
    }

    func testEmptyExistingWriteIsExactAndDurable() throws {
        let fixture = try makeWriteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let originalIdentity = try XCTUnwrap(fixture.originalIdentity)

        let outcome = WorkspaceNoFollowFileWriter.write(
            Data(),
            to: fixture.location,
            expecting: .existing(originalIdentity),
            hooks: .production
        )

        let durable = try XCTUnwrap(requireDurable(outcome))
        XCTAssertEqual(try Data(contentsOf: fixture.destination), Data())
        XCTAssertEqual(durable.metadata.byteCount, 0)
        XCTAssertEqual(durable.metadata, try WorkspaceAnchoredFileSystem.validate(fixture.location))
    }

    func testEmptyMissingWriteIsExactAndDurable() throws {
        let fixture = try makeWriteFixture(originalText: nil)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }

        let outcome = WorkspaceNoFollowFileWriter.write(
            Data(),
            to: fixture.location,
            expecting: .missing,
            hooks: .production
        )

        let durable = try XCTUnwrap(requireDurable(outcome))
        XCTAssertEqual(try Data(contentsOf: fixture.destination), Data())
        XCTAssertEqual(durable.metadata.byteCount, 0)
        XCTAssertEqual(durable.metadata, try WorkspaceAnchoredFileSystem.validate(fixture.location))
    }

    private func assertPreparedMutationCannotCommit(
        _ mutationData: Data,
        at event: WorkspaceAnchoredFileSystem.Event
    ) throws {
        let fixture = try makeWriteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let originalIdentity = try XCTUnwrap(fixture.originalIdentity)
        let mutation = SynchronousMutation {
            try self.overwriteInPlace(
                mutationData,
                at: self.onlyWriteTemporaryURL(for: fixture)
            )
        }
        let hooks = WorkspaceAnchoredFileSystem.Hooks(eventHandler: { observedEvent in
            if observedEvent == event { mutation.run() }
        })

        let outcome = write(
            to: fixture,
            expecting: .existing(originalIdentity),
            hooks: hooks
        )

        try mutation.rethrowIfFailed()
        let result = try XCTUnwrap(requireNotCommitted(outcome, reason: .changedContent))
        XCTAssertEqual(result.artifactState, .none)
        XCTAssertEqual(try writeText(at: fixture.destination), "original")
        XCTAssertEqual(try writeFileIdentity(at: fixture.destination), originalIdentity)
        try assertNoWriteArtifacts(for: fixture)
    }

    private func onlyWriteTemporaryURL(for fixture: WorkspaceWriteFixture) throws -> URL {
        let temporaryURLs = try writeTemporaryURLs(
            in: fixture.destination.deletingLastPathComponent()
        )
        guard temporaryURLs.count == 1, let temporaryURL = temporaryURLs.first else {
            throw WorkspaceWriteTestError.missingTemporary
        }
        return temporaryURL
    }

    private func overwriteInPlace(_ data: Data, at url: URL) throws {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw WorkspaceWriteTestError.openFailed }
        defer { Darwin.close(descriptor) }
        guard Darwin.ftruncate(descriptor, 0) == 0 else {
            throw WorkspaceWriteTestError.truncateFailed
        }
        try WorkspaceAnchoredFileSystem.writeAllBytes(data, descriptor: descriptor)
        guard Darwin.fsync(descriptor) == 0 else {
            throw WorkspaceWriteTestError.syncFailed
        }
    }
}

private enum WorkspaceWriteTestError: Error {
    case missingTemporary
    case unexpectedPermissions
    case openFailed
    case truncateFailed
    case syncFailed
}
