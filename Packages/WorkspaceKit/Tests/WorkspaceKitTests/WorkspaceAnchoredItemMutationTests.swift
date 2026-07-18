import Darwin
@testable import WorkspaceKit
import XCTest

final class WorkspaceAnchoredItemMutationTests: XCTestCase {
    func testRenamePreservesExpectedIdentityAndPreparesCommitAtDestination() throws {
        let fixture = try Fixture()
        let source = try fixture.makeFile("draft.md", text: "draft")
        let destination = try fixture.location("published.md")
        let expectation = try fixture.expectation(at: source)
        var preparedLocation: WorkspaceFileSystemLocation?

        let outcome = try WorkspaceFileOperations().rename(
            source,
            to: "published.md",
            expecting: expectation,
            sourceParentExpectation: fixture.parentExpectation(at: source),
            preparingCommit: { relocation in
                preparedLocation = relocation.destination
                XCTAssertEqual(try fixture.expectation(at: relocation.destination), expectation)
                return "prepared"
            }
        )

        guard case let .movedAndDurable(relocation, preparedCommit) = outcome else {
            return XCTFail("Expected a durable move, got \(outcome)")
        }
        XCTAssertEqual(preparedCommit, "prepared")
        XCTAssertEqual(relocation.source, source)
        XCTAssertEqual(relocation.destination, destination)
        XCTAssertEqual(relocation.expectation, expectation)
        XCTAssertEqual(preparedLocation, destination)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.fileURL.path))
        XCTAssertEqual(try String(contentsOf: destination.fileURL, encoding: .utf8), "draft")
        XCTAssertEqual(try fixture.expectation(at: destination), expectation)
    }

    func testExactInspectorRejectsEquivalentButNonliteralSpelling() throws {
        let fixture = try Fixture()
        let source = try fixture.makeFile("post.md", text: "draft")
        guard try !WorkspaceNoFollowItemInspector.parentIsCaseSensitive(of: source) else {
            throw XCTSkip("Equivalent spelling requires a case-insensitive test volume")
        }
        let expectation = try fixture.expectation(at: source)
        let equivalent = try fixture.location("Post.md")

        XCTAssertEqual(try WorkspaceNoFollowItemInspector.inspect(at: equivalent), expectation)
        XCTAssertThrowsError(try WorkspaceNoFollowItemInspector.inspectExact(at: equivalent)) {
            guard case WorkspaceAnchoredFileSystemError.missing = $0 else {
                return XCTFail("Expected literal entry to be missing, got \($0)")
            }
        }
        XCTAssertEqual(
            try WorkspaceNoFollowItemInspector.inspectExact(at: source),
            expectation
        )
    }

    func testMoveFailsClosedWhenSnapshotIdentityNoLongerMatches() throws {
        let fixture = try Fixture()
        let source = try fixture.makeFile("draft.md", text: "original")
        let expectation = try fixture.expectation(at: source)
        try FileManager.default.removeItem(at: source.fileURL)
        try "replacement".write(to: source.fileURL, atomically: false, encoding: .utf8)
        let destination = try fixture.location("archive/draft.md")
        try fixture.makeDirectory("archive")

        let outcome = try WorkspaceFileOperations().move(
            source,
            to: destination,
            expecting: expectation,
            sourceParentExpectation: fixture.parentExpectation(at: source),
            destinationParentExpectation: fixture.parentExpectation(at: destination)
        )

        guard case .notMoved(.sourceChanged) = outcome else {
            return XCTFail("Expected stale snapshot rejection, got \(outcome)")
        }
        XCTAssertEqual(try String(contentsOf: source.fileURL, encoding: .utf8), "replacement")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.fileURL.path))
    }

    func testMoveFailsClosedWhenDestinationDirectoryWasReplacedAfterSnapshot() throws {
        let fixture = try Fixture()
        let source = try fixture.makeFile("draft.md", text: "source")
        try fixture.makeDirectory("archive")
        let destination = try fixture.location("archive/draft.md")
        let expectation = try fixture.expectation(at: source)
        let sourceParentExpectation = try fixture.parentExpectation(at: source)
        let destinationParentExpectation = try fixture.parentExpectation(at: destination)
        let retainedArchive = try fixture.location("retained-archive")
        try FileManager.default.moveItem(
            at: fixture.location("archive").fileURL,
            to: retainedArchive.fileURL
        )
        try fixture.makeDirectory("archive")

        let outcome = WorkspaceFileOperations().move(
            source,
            to: destination,
            expecting: expectation,
            sourceParentExpectation: sourceParentExpectation,
            destinationParentExpectation: destinationParentExpectation
        )

        guard case .notMoved(.destinationChanged) = outcome else {
            return XCTFail("Expected replacement directory rejection, got \(outcome)")
        }
        XCTAssertEqual(try String(contentsOf: source.fileURL, encoding: .utf8), "source")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.fileURL.path))
    }

    func testMoveNeverOverwritesExistingOrDanglingSymlinkDestination() throws {
        for destinationKind in DestinationOccupantKind.allCases {
            let fixture = try Fixture()
            let source = try fixture.makeFile("draft.md", text: "source")
            let expectation = try fixture.expectation(at: source)
            try fixture.makeDirectory("archive")
            let destination = try fixture.location("archive/draft.md")
            try destinationKind.install(at: destination.fileURL)

            let outcome = try WorkspaceFileOperations().move(
                source,
                to: destination,
                expecting: expectation,
                sourceParentExpectation: fixture.parentExpectation(at: source),
                destinationParentExpectation: fixture.parentExpectation(at: destination)
            )

            guard case .notMoved(.destinationExists) = outcome else {
                return XCTFail("Expected exclusive destination rejection for \(destinationKind), got \(outcome)")
            }
            XCTAssertEqual(try String(contentsOf: source.fileURL, encoding: .utf8), "source")
            XCTAssertTrue(try destinationKind.isStillInstalled(at: destination.fileURL))
        }
    }

    func testDirectoryMoveIntoOwnDescendantIsRejected() throws {
        let fixture = try Fixture()
        let source = try fixture.makeDirectory("posts")
        try fixture.makeDirectory("posts/archive")
        let expectation = try fixture.expectation(at: source)
        let destination = try fixture.location("posts/archive/posts")

        let outcome = try WorkspaceFileOperations().move(
            source,
            to: destination,
            expecting: expectation,
            sourceParentExpectation: fixture.parentExpectation(at: source),
            destinationParentExpectation: fixture.parentExpectation(at: destination)
        )

        guard case .notMoved(.destinationInsideSource) = outcome else {
            return XCTFail("Expected self-descendant rejection, got \(outcome)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.fileURL.path))
    }

    func testCommitPreparationFailureRetainsMovedIdentityWithoutUnsafeReverseRename() throws {
        let fixture = try Fixture()
        let source = try fixture.makeFile("draft.md", text: "source")
        try fixture.makeDirectory("archive")
        let destination = try fixture.location("archive/draft.md")
        let expectation = try fixture.expectation(at: source)

        let outcome: WorkspaceItemMutationOutcome<Void> = try WorkspaceFileOperations().move(
            source,
            to: destination,
            expecting: expectation,
            sourceParentExpectation: fixture.parentExpectation(at: source),
            destinationParentExpectation: fixture.parentExpectation(at: destination),
            preparingCommit: { relocation in
                XCTAssertEqual(try fixture.expectation(at: relocation.destination), expectation)
                throw PreparationError.rejected
            }
        )

        guard case let .movedButIndeterminate(indeterminate) = outcome else {
            return XCTFail("Expected an indeterminate committed rename, got \(outcome)")
        }
        XCTAssertEqual(indeterminate.reason, .commitPreparationFailed)
        XCTAssertEqual(indeterminate.actualMovedExpectation, expectation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.fileURL.path))
        XCTAssertEqual(try fixture.expectation(at: destination), expectation)
        XCTAssertEqual(try String(contentsOf: destination.fileURL, encoding: .utf8), "source")
    }

    func testFinalBoundarySourceReplacementIsReportedWithoutMovingItAgain() throws {
        let fixture = try Fixture()
        let source = try fixture.makeFile("draft.md", text: "expected")
        let expectation = try fixture.expectation(at: source)
        let heldExpected = try fixture.location("held-expected.md")
        let destination = try fixture.location("published.md")
        let gate = OneShotMutation {
            try FileManager.default.moveItem(at: source.fileURL, to: heldExpected.fileURL)
            try "racer".write(to: source.fileURL, atomically: false, encoding: .utf8)
        }
        let hooks = WorkspaceItemMutationHooks(eventHandler: { event in
            if event == .willRename {
                gate.run()
            }
        })

        let outcome = WorkspaceAnchoredItemMutator.relocate(
            source,
            to: destination,
            expecting: expectation,
            sourceParentExpectation: fixture.authority.directoryMutationExpectation,
            destinationParentExpectation: fixture.authority.directoryMutationExpectation,
            preparingCommit: { _ in () },
            hooks: hooks
        )

        guard case let .movedButIndeterminate(indeterminate) = outcome else {
            return XCTFail("Expected the unauthorized move to remain recoverable, got \(outcome)")
        }
        XCTAssertNil(gate.capturedError)
        XCTAssertEqual(indeterminate.reason, .sourceChanged)
        XCTAssertEqual(try fixture.expectation(at: heldExpected), expectation)
        let actualMovedExpectation = try fixture.expectation(at: destination)
        XCTAssertEqual(indeterminate.actualMovedExpectation, actualMovedExpectation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.fileURL.path))
        XCTAssertEqual(try String(contentsOf: destination.fileURL, encoding: .utf8), "racer")
    }

    func testDestinationReplacementBeforeRollbackIsNeverReverseMovedToSource() throws {
        let fixture = try Fixture()
        let source = try fixture.makeFile("draft.md", text: "expected")
        let destination = try fixture.location("published.md")
        let heldExpected = try fixture.location("held-expected.md")
        let expectation = try fixture.expectation(at: source)

        let outcome: WorkspaceItemMutationOutcome<Void> = try WorkspaceFileOperations().move(
            source,
            to: destination,
            expecting: expectation,
            sourceParentExpectation: fixture.parentExpectation(at: source),
            destinationParentExpectation: fixture.parentExpectation(at: destination),
            preparingCommit: { relocation in
                try FileManager.default.moveItem(
                    at: relocation.destination.fileURL,
                    to: heldExpected.fileURL
                )
                try "racer".write(
                    to: relocation.destination.fileURL,
                    atomically: false,
                    encoding: .utf8
                )
                throw PreparationError.rejected
            }
        )

        guard case let .movedButIndeterminate(indeterminate) = outcome else {
            return XCTFail("Expected identity-mismatched rollback refusal, got \(outcome)")
        }
        XCTAssertEqual(indeterminate.reason, .commitPreparationFailed)
        XCTAssertEqual(try fixture.expectation(at: heldExpected), expectation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.fileURL.path))
        XCTAssertEqual(try String(contentsOf: destination.fileURL, encoding: .utf8), "racer")
    }

    func testFinalBoundaryDestinationCreationIsNotOverwritten() throws {
        let fixture = try Fixture()
        let source = try fixture.makeFile("draft.md", text: "expected")
        let destination = try fixture.location("published.md")
        let expectation = try fixture.expectation(at: source)
        let gate = OneShotMutation {
            try "racer".write(to: destination.fileURL, atomically: false, encoding: .utf8)
        }
        let hooks = WorkspaceItemMutationHooks(eventHandler: { event in
            if event == .willRename {
                gate.run()
            }
        })

        let outcome = WorkspaceAnchoredItemMutator.relocate(
            source,
            to: destination,
            expecting: expectation,
            sourceParentExpectation: fixture.authority.directoryMutationExpectation,
            destinationParentExpectation: fixture.authority.directoryMutationExpectation,
            preparingCommit: { _ in () },
            hooks: hooks
        )

        guard case .notMoved(.destinationExists) = outcome else {
            return XCTFail("Expected exclusive-rename rejection, got \(outcome)")
        }
        XCTAssertNil(gate.capturedError)
        XCTAssertEqual(try String(contentsOf: source.fileURL, encoding: .utf8), "expected")
        XCTAssertEqual(try String(contentsOf: destination.fileURL, encoding: .utf8), "racer")
    }

    func testFinalRenameCannotPublishThroughDestinationParentMovedOutsideWorkspace() throws {
        let fixture = try Fixture()
        let source = try fixture.makeFile("draft.md", text: "expected")
        try fixture.makeDirectory("archive")
        let destination = try fixture.location("archive/draft.md")
        let expectation = try fixture.expectation(at: source)
        let sourceParentExpectation = try fixture.parentExpectation(at: source)
        let destinationParentExpectation = try fixture.parentExpectation(at: destination)
        let escapedArchive = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("escaped-archive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: escapedArchive) }
        let gate = OneShotMutation {
            try FileManager.default.moveItem(
                at: fixture.location("archive").fileURL,
                to: escapedArchive
            )
        }
        let hooks = WorkspaceItemMutationHooks(eventHandler: { event in
            if event == .willRename {
                gate.run()
            }
        })

        let outcome = WorkspaceAnchoredItemMutator.relocate(
            source,
            to: destination,
            expecting: expectation,
            sourceParentExpectation: sourceParentExpectation,
            destinationParentExpectation: destinationParentExpectation,
            preparingCommit: { _ in () },
            hooks: hooks
        )

        guard case .notMoved = outcome else {
            return XCTFail("Expected the retained-root rename to fail before escaping, got \(outcome)")
        }
        XCTAssertNil(gate.capturedError)
        XCTAssertEqual(try String(contentsOf: source.fileURL, encoding: .utf8), "expected")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: escapedArchive.appendingPathComponent("draft.md").path
        ))
    }

    func testFinalRenameUsesRetainedSourceParentAfterWorkspacePathReplacement() throws {
        let fixture = try Fixture()
        try fixture.makeDirectory("posts")
        try fixture.makeDirectory("archive")
        let source = try fixture.makeFile("posts/draft.md", text: "expected")
        let destination = try fixture.location("archive/draft.md")
        let expectation = try fixture.expectation(at: source)
        let escapedPosts = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("escaped-posts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: escapedPosts) }
        let gate = OneShotMutation {
            try FileManager.default.moveItem(
                at: fixture.location("posts").fileURL,
                to: escapedPosts
            )
            try fixture.makeDirectory("posts")
            try "foreign".write(
                to: fixture.location("posts/draft.md").fileURL,
                atomically: false,
                encoding: .utf8
            )
        }
        let hooks = WorkspaceItemMutationHooks(eventHandler: { event in
            if event == .willRename {
                gate.run()
            }
        })

        let outcome = try WorkspaceAnchoredItemMutator.relocate(
            source,
            to: destination,
            expecting: expectation,
            sourceParentExpectation: fixture.parentExpectation(at: source),
            destinationParentExpectation: fixture.parentExpectation(at: destination),
            preparingCommit: { _ in () },
            hooks: hooks
        )

        guard case let .movedButIndeterminate(indeterminate) = outcome else {
            return XCTFail("Expected retained-parent move to remain indeterminate, got \(outcome)")
        }
        XCTAssertNil(gate.capturedError)
        XCTAssertEqual(indeterminate.actualMovedExpectation, expectation)
        XCTAssertEqual(
            try String(contentsOf: fixture.location("posts/draft.md").fileURL, encoding: .utf8),
            "foreign"
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: escapedPosts.appendingPathComponent("draft.md").path
        ))
        XCTAssertEqual(try fixture.expectation(at: destination), expectation)
    }
}

extension WorkspaceAnchoredItemMutationTests {
    func testMovedDestinationParentAfterRenameLeavesBothRecordedPathsMissing() throws {
        let fixture = try Fixture()
        let source = try fixture.makeFile("draft.md", text: "expected")
        try fixture.makeDirectory("archive")
        let destination = try fixture.location("archive/draft.md")
        let expectation = try fixture.expectation(at: source)
        let escapedArchive = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("escaped-archive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: escapedArchive) }
        let gate = OneShotMutation {
            try FileManager.default.moveItem(
                at: fixture.location("archive").fileURL,
                to: escapedArchive
            )
        }
        let hooks = WorkspaceItemMutationHooks(eventHandler: { event in
            if event == .didRename {
                gate.run()
            }
        })

        let outcome = try WorkspaceAnchoredItemMutator.relocate(
            source,
            to: destination,
            expecting: expectation,
            sourceParentExpectation: fixture.parentExpectation(at: source),
            destinationParentExpectation: fixture.parentExpectation(at: destination),
            preparingCommit: { _ in () },
            hooks: hooks
        )

        guard case let .movedButIndeterminate(indeterminate) = outcome else {
            return XCTFail("Expected moved-parent result to stay indeterminate, got \(outcome)")
        }
        XCTAssertNil(gate.capturedError)
        XCTAssertEqual(indeterminate.reason, .namespaceChanged)
        XCTAssertEqual(indeterminate.actualMovedExpectation, expectation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.fileURL.path))
        let escapedItem = try WorkspaceFileSystemLocation(
            fileURL: escapedArchive.appendingPathComponent("draft.md")
        )
        XCTAssertEqual(try WorkspaceNoFollowItemInspector.inspect(at: escapedItem), expectation)
    }

    func testRecoveryRestoreUsesResolvedEscapedParentAndLeavesReplacementUntouched() throws {
        let fixture = try Fixture()
        try fixture.makeDirectory("posts")
        try fixture.makeDirectory("archive")
        let source = try fixture.makeFile("posts/draft.md", text: "expected")
        let destination = try fixture.location("archive/draft.md")
        let expectation = try fixture.expectation(at: source)
        let sourceParentExpectation = try fixture.parentExpectation(at: source)
        let destinationParentExpectation = try fixture.parentExpectation(at: destination)
        let escapedArchive = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("escaped-archive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: escapedArchive) }
        let gate = OneShotMutation {
            try FileManager.default.moveItem(
                at: fixture.location("archive").fileURL,
                to: escapedArchive
            )
            try fixture.makeDirectory("archive")
            _ = try fixture.makeFile("archive/replacement.txt", text: "replacement")
        }
        let hooks = WorkspaceItemMutationHooks(eventHandler: { event in
            if event == .didRename {
                gate.run()
            }
        })

        let forwardOutcome = WorkspaceAnchoredItemMutator.relocate(
            source,
            to: destination,
            expecting: expectation,
            sourceParentExpectation: sourceParentExpectation,
            destinationParentExpectation: destinationParentExpectation,
            preparingCommit: { _ in () },
            hooks: hooks
        )

        guard case .movedButIndeterminate = forwardOutcome else {
            return XCTFail("Expected the escaped parent to make the forward move indeterminate")
        }
        XCTAssertNil(gate.capturedError)
        let resolvedMovedSource = try WorkspaceFileSystemLocation(
            fileURL: escapedArchive.appendingPathComponent("draft.md")
        )
        XCTAssertNotEqual(resolvedMovedSource.rootAuthority, source.rootAuthority)

        let restoreOutcome = WorkspaceAnchoredItemMutator.restoreIndeterminateRelocation(
            from: resolvedMovedSource,
            to: source,
            expecting: expectation,
            sourceParentExpectation: destinationParentExpectation,
            destinationParentExpectation: sourceParentExpectation
        )

        guard case let .movedAndDurable(relocation, _) = restoreOutcome else {
            return XCTFail("Expected the retained escaped item to restore, got \(restoreOutcome)")
        }
        XCTAssertEqual(relocation.source, resolvedMovedSource)
        XCTAssertEqual(relocation.destination, source)
        XCTAssertEqual(try fixture.expectation(at: source), expectation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: resolvedMovedSource.fileURL.path))
        XCTAssertEqual(
            try String(
                contentsOf: fixture.location("archive/replacement.txt").fileURL,
                encoding: .utf8
            ),
            "replacement"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.fileURL.path))
    }

    func testRecoveryRestoreCannotPublishThroughTargetParentMovedOutsideWorkspace() throws {
        let fixture = try Fixture()
        try fixture.makeDirectory("recovery-parent")
        try fixture.makeDirectory("posts")
        let retainedSource = try fixture.makeFile(
            "recovery-parent/draft.md",
            text: "expected"
        )
        let resolvedSource = try WorkspaceFileSystemLocation(
            fileURL: retainedSource.fileURL
        )
        let destination = try fixture.location("posts/draft.md")
        let expectation = try fixture.expectation(at: resolvedSource)
        let escapedPosts = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("escaped-posts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: escapedPosts) }
        let gate = OneShotMutation {
            try FileManager.default.moveItem(
                at: fixture.location("posts").fileURL,
                to: escapedPosts
            )
        }
        let hooks = WorkspaceItemMutationHooks(eventHandler: { event in
            if event == .willRename {
                gate.run()
            }
        })

        let outcome = try WorkspaceAnchoredItemMutator.restoreIndeterminateRelocation(
            from: resolvedSource,
            to: destination,
            expecting: expectation,
            sourceParentExpectation: fixture.parentExpectation(at: resolvedSource),
            destinationParentExpectation: fixture.parentExpectation(at: destination),
            hooks: hooks
        )

        guard case .notMoved = outcome else {
            return XCTFail("Expected target-parent escape to fail before publication, got \(outcome)")
        }
        XCTAssertNil(gate.capturedError)
        XCTAssertEqual(try fixture.expectation(at: resolvedSource), expectation)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: escapedPosts.appendingPathComponent("draft.md").path
        ))
    }

    func testForwardRelocationStillRejectsDifferentRootAuthority() throws {
        let fixture = try Fixture()
        let source = try fixture.makeFile("draft.md", text: "expected")
        try fixture.makeDirectory("other-parent")
        let standaloneDestination = try WorkspaceFileSystemLocation(
            fileURL: fixture.location("other-parent/published.md").fileURL
        )
        let expectation = try fixture.expectation(at: source)

        let outcome = try WorkspaceAnchoredItemMutator.relocate(
            source,
            to: standaloneDestination,
            expecting: expectation,
            sourceParentExpectation: fixture.parentExpectation(at: source),
            destinationParentExpectation: fixture.parentExpectation(at: standaloneDestination),
            preparingCommit: { _ in () },
            hooks: .production
        )

        guard case .notMoved(.differentRootAuthority) = outcome else {
            return XCTFail("Expected forward cross-authority rejection, got \(outcome)")
        }
        XCTAssertEqual(try fixture.expectation(at: source), expectation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: standaloneDestination.fileURL.path))
    }

    func testRecoveryRestoreRejectsMultiComponentSourceAuthorityBeforeRename() throws {
        let fixture = try Fixture()
        try fixture.makeDirectory("recovery-parent/nested")
        let retainedSource = try fixture.makeFile(
            "recovery-parent/nested/draft.md",
            text: "expected"
        )
        let expectation = try fixture.expectation(at: retainedSource)
        let heldParent = try fixture.location("held-nested")
        let destination = try fixture.location("restored.md")
        let gate = OneShotMutation {
            try FileManager.default.moveItem(
                at: fixture.location("recovery-parent/nested").fileURL,
                to: heldParent.fileURL
            )
            try fixture.makeDirectory("recovery-parent/nested")
            _ = try fixture.makeFile("recovery-parent/nested/draft.md", text: "racer")
        }
        let hooks = WorkspaceItemMutationHooks(eventHandler: { event in
            if event == .willRename {
                gate.run()
            }
        })

        let outcome = try WorkspaceAnchoredItemMutator.restoreIndeterminateRelocation(
            from: retainedSource,
            to: destination,
            expecting: expectation,
            sourceParentExpectation: fixture.parentExpectation(at: retainedSource),
            destinationParentExpectation: fixture.parentExpectation(at: destination),
            hooks: hooks
        )

        guard case .notMoved(.sourceChanged) = outcome else {
            return XCTFail("Expected non-exact parent authority rejection, got \(outcome)")
        }
        XCTAssertNil(gate.capturedError)
        XCTAssertEqual(try fixture.expectation(at: retainedSource), expectation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: heldParent.fileURL.path))
    }

    func testRecoveryRestoreRejectsWorkspaceSourceCollision() throws {
        let fixture = try Fixture()
        try fixture.makeDirectory("recovery-parent")
        try fixture.makeDirectory("posts")
        let retainedSource = try fixture.makeFile("recovery-parent/draft.md", text: "expected")
        let resolvedRetainedSource = try WorkspaceFileSystemLocation(fileURL: retainedSource.fileURL)
        let expectation = try fixture.expectation(at: resolvedRetainedSource)
        let destination = try fixture.makeFile("posts/draft.md", text: "racer")

        let outcome = try WorkspaceAnchoredItemMutator.restoreIndeterminateRelocation(
            from: resolvedRetainedSource,
            to: destination,
            expecting: expectation,
            sourceParentExpectation: fixture.parentExpectation(at: resolvedRetainedSource),
            destinationParentExpectation: fixture.parentExpectation(at: destination)
        )

        guard case .notMoved(.destinationExists) = outcome else {
            return XCTFail("Expected occupied workspace source rejection, got \(outcome)")
        }
        XCTAssertEqual(
            try String(contentsOf: resolvedRetainedSource.fileURL, encoding: .utf8),
            "expected"
        )
        XCTAssertEqual(try String(contentsOf: destination.fileURL, encoding: .utf8), "racer")
    }

    func testRecoveryRestoreRejectsMissingRetainedLeaf() throws {
        let fixture = try Fixture()
        try fixture.makeDirectory("recovery-parent")
        let retainedSource = try fixture.makeFile("recovery-parent/draft.md", text: "expected")
        let resolvedRetainedSource = try WorkspaceFileSystemLocation(fileURL: retainedSource.fileURL)
        let expectation = try fixture.expectation(at: resolvedRetainedSource)
        let sourceParentExpectation = try fixture.parentExpectation(at: resolvedRetainedSource)
        let heldExpected = try fixture.location("held-expected.md")
        try FileManager.default.moveItem(at: resolvedRetainedSource.fileURL, to: heldExpected.fileURL)
        let destination = try fixture.location("draft.md")

        let outcome = try WorkspaceAnchoredItemMutator.restoreIndeterminateRelocation(
            from: resolvedRetainedSource,
            to: destination,
            expecting: expectation,
            sourceParentExpectation: sourceParentExpectation,
            destinationParentExpectation: fixture.parentExpectation(at: destination)
        )

        guard case .notMoved(.sourceMissing) = outcome else {
            return XCTFail("Expected missing retained leaf rejection, got \(outcome)")
        }
        XCTAssertEqual(try fixture.expectation(at: heldExpected), expectation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.fileURL.path))
    }

    func testRecoveryRestoreRejectsReplacedRetainedLeaf() throws {
        let fixture = try Fixture()
        try fixture.makeDirectory("recovery-parent")
        let retainedSource = try fixture.makeFile("recovery-parent/draft.md", text: "expected")
        let resolvedRetainedSource = try WorkspaceFileSystemLocation(fileURL: retainedSource.fileURL)
        let expectation = try fixture.expectation(at: resolvedRetainedSource)
        let sourceParentExpectation = try fixture.parentExpectation(at: resolvedRetainedSource)
        let heldExpected = try fixture.location("held-expected.md")
        try FileManager.default.moveItem(at: resolvedRetainedSource.fileURL, to: heldExpected.fileURL)
        try "replacement".write(
            to: resolvedRetainedSource.fileURL,
            atomically: false,
            encoding: .utf8
        )
        let destination = try fixture.location("draft.md")

        let outcome = try WorkspaceAnchoredItemMutator.restoreIndeterminateRelocation(
            from: resolvedRetainedSource,
            to: destination,
            expecting: expectation,
            sourceParentExpectation: sourceParentExpectation,
            destinationParentExpectation: fixture.parentExpectation(at: destination)
        )

        guard case .notMoved(.sourceChanged) = outcome else {
            return XCTFail("Expected replaced retained leaf rejection, got \(outcome)")
        }
        XCTAssertEqual(try fixture.expectation(at: heldExpected), expectation)
        XCTAssertEqual(
            try String(contentsOf: resolvedRetainedSource.fileURL, encoding: .utf8),
            "replacement"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.fileURL.path))
    }
}

extension WorkspaceAnchoredItemMutationTests {
    func testRenamePublishesCaseAndCanonicalOnlyLiteralSpellingChanges() throws {
        let spellingPairs = [
            ("post.md", "Post.md"),
            ("caf\u{00E9}.md", "cafe\u{0301}.md"),
        ]

        for (sourceName, destinationName) in spellingPairs {
            let fixture = try Fixture()
            guard try !fixture.parentIsCaseSensitive else {
                throw XCTSkip("Equivalent-spelling rename requires a case-insensitive test volume")
            }
            let source = try fixture.makeExactEmptyFile(sourceName)
            let expectation = try fixture.expectation(at: source)

            let outcome = WorkspaceFileOperations().rename(
                source,
                to: destinationName,
                expecting: expectation,
                sourceParentExpectation: fixture.authority.directoryMutationExpectation
            )

            guard case .movedAndDurable = outcome else {
                return XCTFail(
                    "Expected \(sourceName) -> \(destinationName) to publish exact spelling, got \(outcome)"
                )
            }
            let names = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
                .map { Array($0.utf8) }
            XCTAssertFalse(names.contains(Array(sourceName.utf8)))
            XCTAssertTrue(names.contains(Array(destinationName.utf8)))
        }
    }

    func testRenameMovesSymbolicLinkItselfWithoutTouchingTarget() throws {
        let fixture = try Fixture()
        let target = try fixture.makeFile("target.md", text: "target")
        let source = try fixture.location("alias.md")
        try FileManager.default.createSymbolicLink(
            atPath: source.fileURL.path,
            withDestinationPath: target.fileURL.lastPathComponent
        )
        let expectation = try fixture.expectation(at: source)
        XCTAssertEqual(expectation.kind, .symbolicLink)

        let outcome = try WorkspaceFileOperations().rename(
            source,
            to: "renamed-alias.md",
            expecting: expectation,
            sourceParentExpectation: fixture.parentExpectation(at: source)
        )

        guard case let .movedAndDurable(relocation, _) = outcome else {
            return XCTFail("Expected symlink relocation, got \(outcome)")
        }
        XCTAssertEqual(try fixture.expectation(at: relocation.destination), expectation)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: relocation.destination.fileURL.path),
            "target.md"
        )
        XCTAssertEqual(try String(contentsOf: target.fileURL, encoding: .utf8), "target")
    }
}

private enum PreparationError: Error {
    case rejected
}

private enum DestinationOccupantKind: CaseIterable, CustomStringConvertible {
    case file
    case directory
    case danglingSymbolicLink

    var description: String {
        switch self {
        case .file: "file"
        case .directory: "directory"
        case .danglingSymbolicLink: "dangling symbolic link"
        }
    }

    func install(at url: URL) throws {
        switch self {
        case .file:
            try "destination".write(to: url, atomically: false, encoding: .utf8)
        case .directory:
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        case .danglingSymbolicLink:
            try FileManager.default.createSymbolicLink(
                atPath: url.path,
                withDestinationPath: "missing-target"
            )
        }
    }

    func isStillInstalled(at url: URL) throws -> Bool {
        switch self {
        case .file:
            try String(contentsOf: url, encoding: .utf8) == "destination"
        case .directory:
            try (url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true
        case .danglingSymbolicLink:
            try FileManager.default.destinationOfSymbolicLink(atPath: url.path) == "missing-target"
        }
    }
}

private final class OneShotMutation: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (() throws -> Void)?
    private var error: Error?

    var capturedError: Error? {
        lock.lock()
        defer { lock.unlock() }
        return error
    }

    init(_ action: @escaping () throws -> Void) {
        self.action = action
    }

    func run() {
        lock.lock()
        let action = action
        self.action = nil
        lock.unlock()
        do {
            try action?()
        } catch {
            lock.lock()
            self.error = error
            lock.unlock()
        }
    }
}

private final class Fixture {
    let root: URL
    let authority: WorkspaceFileSystemRootAuthority

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceAnchoredItemMutationTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func location(_ relativePath: String) throws -> WorkspaceFileSystemLocation {
        try authority.location(relativePath: relativePath)
    }

    @discardableResult
    func makeDirectory(_ relativePath: String) throws -> WorkspaceFileSystemLocation {
        let location = try location(relativePath)
        try FileManager.default.createDirectory(
            at: location.fileURL,
            withIntermediateDirectories: true
        )
        return location
    }

    func makeFile(_ relativePath: String, text: String) throws -> WorkspaceFileSystemLocation {
        let location = try location(relativePath)
        try text.write(to: location.fileURL, atomically: false, encoding: .utf8)
        return location
    }

    func makeExactEmptyFile(_ relativePath: String) throws -> WorkspaceFileSystemLocation {
        let descriptor = authority.withRetainedRootDescriptor { rootDescriptor in
            relativePath.withCString {
                Darwin.openat(
                    rootDescriptor,
                    $0,
                    O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW_ANY,
                    mode_t(S_IRUSR | S_IWUSR)
                )
            }
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        Darwin.close(descriptor)
        return try location(relativePath)
    }

    var parentIsCaseSensitive: Bool {
        get throws {
            try authority.withRetainedRootDescriptor { descriptor in
                errno = 0
                let result = Darwin.fpathconf(descriptor, _PC_CASE_SENSITIVE)
                guard result >= 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                return result != 0
            }
        }
    }

    func expectation(at location: WorkspaceFileSystemLocation) throws -> WorkspaceItemMutationExpectation {
        var status = stat()
        guard lstat(location.fileURL.path, &status) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return WorkspaceItemMutationExpectation(
            identity: WorkspaceFileSystemIdentity(
                device: UInt64(status.st_dev),
                inode: UInt64(status.st_ino)
            ),
            kind: WorkspaceFileSystemItemKind(mode: status.st_mode)
        )
    }

    func parentExpectation(
        at location: WorkspaceFileSystemLocation
    ) throws -> WorkspaceItemMutationExpectation {
        try WorkspaceNoFollowItemInspector.inspectParent(of: location)
    }
}
