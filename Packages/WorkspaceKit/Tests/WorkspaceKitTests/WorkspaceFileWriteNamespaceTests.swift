import Foundation
@testable import WorkspaceKit
import XCTest

extension WorkspaceAnchoredFileSystemTests {
    func testWriteRejectsIntermediateSymlinkSubstitutionBeforeOpeningComponent() throws {
        let fixture = try makeWriteFixture(relativePath: "nested/post.md")
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let originalIdentity = try XCTUnwrap(fixture.originalIdentity)
        let nested = fixture.root.appendingPathComponent("nested", isDirectory: true)
        let moved = fixture.root.appendingPathComponent("moved", isDirectory: true)
        let outsideDirectory = fixture.parent.appendingPathComponent("outside", isDirectory: true)
        let outsideTarget = outsideDirectory.appendingPathComponent("post.md")
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        try "outside target".write(to: outsideTarget, atomically: true, encoding: .utf8)
        let mutation = SynchronousMutation {
            try FileManager.default.moveItem(at: nested, to: moved)
            try FileManager.default.createSymbolicLink(at: nested, withDestinationURL: outsideDirectory)
        }
        let hooks = WorkspaceAnchoredFileSystem.Hooks(eventHandler: { event in
            if event == .rootAnchored { mutation.run() }
        })

        let outcome = write(
            to: fixture,
            expecting: .existing(originalIdentity),
            hooks: hooks
        )

        try mutation.rethrowIfFailed()
        let result = try XCTUnwrap(requireNotCommitted(outcome, reason: .symbolicLink))
        XCTAssertEqual(result.artifactState, .none)
        XCTAssertEqual(try writeText(at: moved.appendingPathComponent("post.md")), "original")
        XCTAssertEqual(
            try writeFileIdentity(at: moved.appendingPathComponent("post.md")),
            originalIdentity
        )
        XCTAssertEqual(try writeText(at: outsideTarget), "outside target")
        try assertNoWriteTemporaryFiles(in: moved)
        try assertNoWriteTemporaryFiles(in: outsideDirectory)
        try assertFixtureSentinel(fixture)
    }

    func testWriteRejectsIntermediateRenameReplacementAfterComponentOpen() throws {
        let fixture = try makeWriteFixture(relativePath: "nested/post.md")
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let originalIdentity = try XCTUnwrap(fixture.originalIdentity)
        let nested = fixture.root.appendingPathComponent("nested", isDirectory: true)
        let moved = fixture.root.appendingPathComponent("moved-nested", isDirectory: true)
        let mutation = SynchronousMutation {
            try FileManager.default.moveItem(at: nested, to: moved)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try "replacement".write(to: fixture.destination, atomically: true, encoding: .utf8)
        }
        let hooks = WorkspaceAnchoredFileSystem.Hooks(eventHandler: { event in
            if event == .componentOpened("nested") { mutation.run() }
        })

        let outcome = write(
            to: fixture,
            expecting: .existing(originalIdentity),
            hooks: hooks
        )

        try mutation.rethrowIfFailed()
        let result = try XCTUnwrap(requireNotCommitted(outcome, reason: .namespaceChanged))
        XCTAssertEqual(result.artifactState, .none)
        try assertReplacementRace(
            fixture: fixture,
            movedDestination: moved.appendingPathComponent("post.md"),
            originalIdentity: originalIdentity
        )
        try assertNoWriteTemporaryFiles(in: nested)
        try assertNoWriteTemporaryFiles(in: moved)
    }

    func testWriteRejectsWorkspaceRootMoveReplacementAfterAnchoring() throws {
        let fixture = try makeWriteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let originalIdentity = try XCTUnwrap(fixture.originalIdentity)
        let movedRoot = fixture.parent.appendingPathComponent("moved-workspace", isDirectory: true)
        let mutation = SynchronousMutation {
            try FileManager.default.moveItem(at: fixture.root, to: movedRoot)
            try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
            try "replacement".write(to: fixture.destination, atomically: true, encoding: .utf8)
        }
        let hooks = WorkspaceAnchoredFileSystem.Hooks(eventHandler: { event in
            if event == .rootAnchored { mutation.run() }
        })

        let outcome = write(
            to: fixture,
            expecting: .existing(originalIdentity),
            hooks: hooks
        )

        try mutation.rethrowIfFailed()
        let result = try XCTUnwrap(requireNotCommitted(outcome, reason: .namespaceChanged))
        XCTAssertEqual(result.artifactState, .none)
        try assertReplacementRace(
            fixture: fixture,
            movedDestination: movedRoot.appendingPathComponent("post.md"),
            originalIdentity: originalIdentity
        )
        try assertNoWriteTemporaryFiles(in: fixture.root)
        try assertNoWriteTemporaryFiles(in: movedRoot)
    }

    func testWriteRejectsFinalParentReplacementAfterItWasOpened() throws {
        let fixture = try makeWriteFixture(relativePath: "outer/final/post.md")
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let originalIdentity = try XCTUnwrap(fixture.originalIdentity)
        let finalParent = fixture.destination.deletingLastPathComponent()
        let movedParent = finalParent.deletingLastPathComponent()
            .appendingPathComponent("moved-final", isDirectory: true)
        let mutation = SynchronousMutation {
            try FileManager.default.moveItem(at: finalParent, to: movedParent)
            try FileManager.default.createDirectory(at: finalParent, withIntermediateDirectories: true)
            try "replacement".write(to: fixture.destination, atomically: true, encoding: .utf8)
        }
        let hooks = WorkspaceAnchoredFileSystem.Hooks(eventHandler: { event in
            if event == .componentOpened("final") { mutation.run() }
        })

        let outcome = write(
            to: fixture,
            expecting: .existing(originalIdentity),
            hooks: hooks
        )

        try mutation.rethrowIfFailed()
        let result = try XCTUnwrap(requireNotCommitted(outcome, reason: .namespaceChanged))
        XCTAssertEqual(result.artifactState, .none)
        try assertReplacementRace(
            fixture: fixture,
            movedDestination: movedParent.appendingPathComponent("post.md"),
            originalIdentity: originalIdentity
        )
        try assertNoWriteTemporaryFiles(in: finalParent)
        try assertNoWriteTemporaryFiles(in: movedParent)
    }

    func testWriteRejectsLeafSubstitutionAfterTargetAndTemporaryFileOpen() throws {
        let fixture = try makeWriteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let originalIdentity = try XCTUnwrap(fixture.originalIdentity)
        let moved = fixture.root.appendingPathComponent("moved.md")
        let mutation = SynchronousMutation {
            try FileManager.default.moveItem(at: fixture.destination, to: moved)
            try "replacement".write(to: fixture.destination, atomically: true, encoding: .utf8)
        }
        let hooks = WorkspaceAnchoredFileSystem.Hooks(eventHandler: { event in
            if event == .temporaryFileCreated { mutation.run() }
        })

        let outcome = write(
            to: fixture,
            expecting: .existing(originalIdentity),
            hooks: hooks
        )

        try mutation.rethrowIfFailed()
        let result = try XCTUnwrap(requireIndeterminate(outcome, reason: .changedIdentity))
        XCTAssertNotNil(result.preparedMetadata)
        XCTAssertEqual(result.recoveryArtifact, .none)
        try assertReplacementRace(
            fixture: fixture,
            movedDestination: moved,
            originalIdentity: originalIdentity
        )
        try assertNoWriteArtifacts(for: fixture)
    }

    func testNamespaceMoveAfterSwapReportsIndeterminateWithoutDetachedRollback() throws {
        let fixture = try makeWriteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let originalIdentity = try XCTUnwrap(fixture.originalIdentity)
        let movedRoot = fixture.parent.appendingPathComponent("moved-after-commit", isDirectory: true)
        let mutation = SynchronousMutation {
            try FileManager.default.moveItem(at: fixture.root, to: movedRoot)
            try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
            try "canonical replacement".write(
                to: fixture.destination,
                atomically: true,
                encoding: .utf8
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
        let result = try XCTUnwrap(requireIndeterminate(outcome, reason: .namespaceChanged))
        let preparedMetadata = try XCTUnwrap(result.preparedMetadata)
        guard case let .removalIndeterminate(artifact) = result.recoveryArtifact else {
            return XCTFail("Expected indeterminate rollback material, got \(result.recoveryArtifact)")
        }
        let movedDestination = movedRoot.appendingPathComponent("post.md")
        let movedArtifact = movedRoot.appendingPathComponent(artifact.relativePath)
        XCTAssertEqual(try writeText(at: fixture.destination), "canonical replacement")
        XCTAssertEqual(try writeText(at: movedDestination), "replacement bytes")
        XCTAssertEqual(try writeFileIdentity(at: movedDestination), preparedMetadata.identity)
        XCTAssertEqual(try writeText(at: movedArtifact), "original")
        XCTAssertEqual(try writeFileIdentity(at: movedArtifact), originalIdentity)
        XCTAssertEqual(
            try writeTemporaryURLs(in: movedRoot).map(\.lastPathComponent),
            [movedArtifact.lastPathComponent]
        )
        try assertNoWriteTemporaryFiles(in: fixture.root)
        try assertFixtureSentinel(fixture)
    }

    func testWorkspaceRootMoveAtWillCommitFailsBeforeSwap() throws {
        let fixture = try makeWriteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let originalIdentity = try XCTUnwrap(fixture.originalIdentity)
        let movedRoot = fixture.parent.appendingPathComponent("moved-before-commit", isDirectory: true)
        let mutation = SynchronousMutation {
            try FileManager.default.moveItem(at: fixture.root, to: movedRoot)
            try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
            try "replacement".write(to: fixture.destination, atomically: true, encoding: .utf8)
        }
        let hooks = WorkspaceAnchoredFileSystem.Hooks(eventHandler: { event in
            if event == .willCommit(.swap) { mutation.run() }
        })

        let outcome = write(
            to: fixture,
            expecting: .existing(originalIdentity),
            hooks: hooks
        )

        try mutation.rethrowIfFailed()
        let result = try XCTUnwrap(requireIndeterminate(outcome, reason: .namespaceChanged))
        XCTAssertNotNil(result.preparedMetadata)
        guard case let .removalIndeterminate(artifact) = result.recoveryArtifact else {
            return XCTFail("Expected indeterminate prepared cleanup, got \(result.recoveryArtifact)")
        }
        try assertReplacementRace(
            fixture: fixture,
            movedDestination: movedRoot.appendingPathComponent("post.md"),
            originalIdentity: originalIdentity
        )
        try assertNoWriteTemporaryFiles(in: fixture.root)
        let movedArtifact = movedRoot.appendingPathComponent(artifact.relativePath)
        XCTAssertEqual(try writeText(at: movedArtifact), "replacement bytes")
        XCTAssertEqual(
            try writeTemporaryURLs(in: movedRoot).map(\.lastPathComponent),
            [movedArtifact.lastPathComponent]
        )
    }

    func testWorkspaceRootMoveAtRollbackHookReportsIndeterminateWithoutDetachedSwap() throws {
        let fixture = try makeWriteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let originalIdentity = try XCTUnwrap(fixture.originalIdentity)
        let movedRoot = fixture.parent.appendingPathComponent("moved-during-rollback", isDirectory: true)
        let mutation = SynchronousMutation {
            try FileManager.default.moveItem(at: fixture.root, to: movedRoot)
            try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
            try "canonical replacement".write(
                to: fixture.destination,
                atomically: true,
                encoding: .utf8
            )
        }
        let hooks = WorkspaceAnchoredFileSystem.Hooks(injectedFailure: { call in
            switch call {
            case .validateCommittedLeaf:
                .durabilityFailed
            case .renameRollback:
                {
                    mutation.run()
                    return nil
                }()
            default:
                nil
            }
        })

        let outcome = write(
            to: fixture,
            expecting: .existing(originalIdentity),
            hooks: hooks
        )

        try mutation.rethrowIfFailed()
        let result = try XCTUnwrap(requireIndeterminate(outcome, reason: .namespaceChanged))
        let preparedMetadata = try XCTUnwrap(result.preparedMetadata)
        guard case let .removalIndeterminate(artifact) = result.recoveryArtifact else {
            return XCTFail("Expected indeterminate rollback material, got \(result.recoveryArtifact)")
        }
        let movedDestination = movedRoot.appendingPathComponent("post.md")
        let movedArtifact = movedRoot.appendingPathComponent(artifact.relativePath)
        XCTAssertEqual(try writeText(at: fixture.destination), "canonical replacement")
        XCTAssertEqual(try writeText(at: movedDestination), "replacement bytes")
        XCTAssertEqual(try writeFileIdentity(at: movedDestination), preparedMetadata.identity)
        XCTAssertEqual(try writeText(at: movedArtifact), "original")
        XCTAssertEqual(try writeFileIdentity(at: movedArtifact), originalIdentity)
        XCTAssertEqual(
            try writeTemporaryURLs(in: movedRoot).map(\.lastPathComponent),
            [movedArtifact.lastPathComponent]
        )
        try assertNoWriteTemporaryFiles(in: fixture.root)
        try assertFixtureSentinel(fixture)
    }
}

private extension WorkspaceAnchoredFileSystemTests {
    func assertReplacementRace(
        fixture: WorkspaceWriteFixture,
        movedDestination: URL,
        originalIdentity: WorkspaceFileSystemIdentity,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(try writeText(at: fixture.destination), "replacement", file: file, line: line)
        XCTAssertNotEqual(
            try writeFileIdentity(at: fixture.destination),
            originalIdentity,
            file: file,
            line: line
        )
        XCTAssertEqual(try writeText(at: movedDestination), "original", file: file, line: line)
        XCTAssertEqual(
            try writeFileIdentity(at: movedDestination),
            originalIdentity,
            file: file,
            line: line
        )
        try assertFixtureSentinel(fixture, file: file, line: line)
    }
}
