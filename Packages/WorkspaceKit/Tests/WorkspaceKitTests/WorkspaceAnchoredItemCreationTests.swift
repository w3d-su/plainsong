import Darwin
@testable import WorkspaceKit
import XCTest

// The file/folder scenario halves stay adjacent so each staging contract is reviewed
// symmetrically.
// swiftlint:disable file_length
// swiftlint:disable:next type_body_length
final class WorkspaceAnchoredItemCreationTests: XCTestCase {
    func testAnchoredFacadeCreatesFileAndDirectoryUnderExactParent() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let operations = WorkspaceFileOperations()

        let file = try requireCreated(operations.createFile(
            named: "post.md",
            inDirectoryRelativePath: "drafts",
            rootAuthority: fixture.authority,
            expectingDirectory: fixture.draftsExpectation
        ))
        XCTAssertEqual(file.location, try fixture.location("drafts/post.md"))
        XCTAssertEqual(file.expectation.kind, .regularFile)
        XCTAssertEqual(try Data(contentsOf: file.location.fileURL), Data())

        let folder = try requireCreated(operations.createFolder(
            named: "images",
            inDirectoryRelativePath: "drafts",
            rootAuthority: fixture.authority,
            expectingDirectory: fixture.draftsExpectation
        ))
        XCTAssertEqual(folder.location, try fixture.location("drafts/images"))
        XCTAssertEqual(folder.expectation.kind, .directory)
        XCTAssertTrue(try isDirectory(folder.location.fileURL))
        XCTAssertTrue(try creationStagingEntries(in: fixture.root).isEmpty)
    }

    func testAnchoredFacadeRejectsInvalidNamesAndDirectoryTraversal() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let operations = WorkspaceFileOperations()

        for name in ["../outside.md", "child/post.md", ".", "..", "bad\0name.md"] {
            XCTAssertEqual(
                operations.createFile(
                    named: name,
                    inDirectoryRelativePath: "drafts",
                    rootAuthority: fixture.authority,
                    expectingDirectory: fixture.draftsExpectation
                ),
                .notCreated(.invalidName)
            )
        }
        XCTAssertEqual(
            operations.createFolder(
                named: "escaped",
                inDirectoryRelativePath: "drafts/../outside",
                rootAuthority: fixture.authority,
                expectingDirectory: fixture.draftsExpectation
            ),
            .notCreated(.destinationChanged)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url("outside.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url("drafts/child").path))
        XCTAssertTrue(try creationStagingEntries(in: fixture.root).isEmpty)
    }

    func testCreationPlansReserveDistinctLiteralRootStagingLocations() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let operations = WorkspaceFileOperations()

        let filePlan = try operations.makeFileCreationPlan(
            named: "post.md",
            inDirectoryRelativePath: "drafts",
            rootAuthority: fixture.authority,
            expectingDirectory: fixture.draftsExpectation
        )
        let folderPlan = try operations.makeFolderCreationPlan(
            named: "images",
            inDirectoryRelativePath: "drafts",
            rootAuthority: fixture.authority,
            expectingDirectory: fixture.draftsExpectation
        )

        let fileStaging = try XCTUnwrap(filePlan.stagingLocation)
        let folderStaging = try XCTUnwrap(folderPlan.stagingLocation)
        for staging in [fileStaging, folderStaging] {
            XCTAssertEqual(staging.rootAuthority, fixture.authority)
            XCTAssertTrue(staging.relativePath.hasPrefix(".plainsong-create-"))
            XCTAssertFalse(staging.relativePath.contains("/"))
            XCTAssertEqual(
                try WorkspaceNoFollowItemInspector.inspectParent(of: staging),
                fixture.authority.directoryMutationExpectation
            )
            XCTAssertThrowsError(try WorkspaceNoFollowItemInspector.inspectExact(at: staging))
        }
        XCTAssertNotEqual(fileStaging, folderStaging)
        XCTAssertNotEqual(fileStaging, filePlan.destination)
        XCTAssertNotEqual(folderStaging, folderPlan.destination)
    }

    func testFileCallbackRecordsDurableStagingBeforeDestinationPublication() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let operations = WorkspaceFileOperations()
        let plan = try fixture.filePlan(operations: operations)
        let staging = try XCTUnwrap(plan.stagingLocation)
        var recorded: WorkspacePreparedItemCreationArtifact?

        let outcome = operations.createFile(
            using: plan,
            recordingCreatedArtifact: { artifact in
                recorded = artifact
                XCTAssertEqual(artifact.location, staging)
                XCTAssertEqual(
                    try WorkspaceNoFollowItemInspector.inspectExact(at: staging),
                    artifact.expectation
                )
                XCTAssertFalse(FileManager.default.fileExists(
                    atPath: plan.destination.fileURL.path
                ))
            }
        )

        let created = try requireCreated(outcome)
        XCTAssertEqual(recorded?.expectation, created.expectation)
        XCTAssertThrowsError(try WorkspaceNoFollowItemInspector.inspectExact(at: staging))
        XCTAssertEqual(
            try WorkspaceNoFollowItemInspector.inspectExact(at: plan.destination),
            created.expectation
        )
    }

    func testFolderCallbackRecordsDurableStagingBeforeDestinationPublication() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let operations = WorkspaceFileOperations()
        let plan = try fixture.folderPlan(operations: operations)
        let staging = try XCTUnwrap(plan.stagingLocation)
        var recorded: WorkspacePreparedItemCreationArtifact?

        let outcome = operations.createFolder(
            using: plan,
            recordingCreatedArtifact: { artifact in
                recorded = artifact
                XCTAssertEqual(artifact.location, staging)
                XCTAssertEqual(
                    try WorkspaceNoFollowItemInspector.inspectExact(at: staging),
                    artifact.expectation
                )
                XCTAssertTrue(try self.isDirectory(staging.fileURL))
                XCTAssertFalse(FileManager.default.fileExists(
                    atPath: plan.destination.fileURL.path
                ))
            }
        )

        let created = try requireCreated(outcome)
        XCTAssertEqual(recorded?.expectation, created.expectation)
        XCTAssertThrowsError(try WorkspaceNoFollowItemInspector.inspectExact(at: staging))
        XCTAssertEqual(
            try WorkspaceNoFollowItemInspector.inspectExact(at: plan.destination),
            created.expectation
        )
    }

    func testFileRecordingFailureRetainsExactRootStagingArtifact() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let operations = WorkspaceFileOperations()
        let plan = try fixture.filePlan(operations: operations)
        let staging = try XCTUnwrap(plan.stagingLocation)
        var recorded: WorkspacePreparedItemCreationArtifact?

        let outcome = operations.createFile(
            using: plan,
            recordingCreatedArtifact: {
                recorded = $0
                throw TestFailure.recordingFailed
            }
        )

        let indeterminate = try requireIndeterminate(outcome)
        let expectation = try XCTUnwrap(recorded?.expectation)
        XCTAssertEqual(indeterminate.destination, plan.destination)
        XCTAssertEqual(indeterminate.reason, .commitPreparationFailed)
        XCTAssertEqual(indeterminate.recoveryState, .retained(staging))
        XCTAssertEqual(indeterminate.createdExpectation, expectation)
        XCTAssertEqual(indeterminate.recoveryExpectation, expectation)
        XCTAssertEqual(indeterminate.publicationSource, staging)
        XCTAssertNil(indeterminate.actualPublishedExpectation)
        XCTAssertEqual(
            try WorkspaceNoFollowItemInspector.inspectExact(at: staging),
            expectation
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.destination.fileURL.path))
    }

    func testFolderRecordingFailureRetainsExactRootStagingArtifact() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let operations = WorkspaceFileOperations()
        let plan = try fixture.folderPlan(operations: operations)
        let staging = try XCTUnwrap(plan.stagingLocation)
        var recorded: WorkspacePreparedItemCreationArtifact?

        let outcome = operations.createFolder(
            using: plan,
            recordingCreatedArtifact: {
                recorded = $0
                throw TestFailure.recordingFailed
            }
        )

        let indeterminate = try requireIndeterminate(outcome)
        let expectation = try XCTUnwrap(recorded?.expectation)
        XCTAssertEqual(indeterminate.destination, plan.destination)
        XCTAssertEqual(indeterminate.reason, .commitPreparationFailed)
        XCTAssertEqual(indeterminate.recoveryState, .retained(staging))
        XCTAssertEqual(indeterminate.createdExpectation, expectation)
        XCTAssertEqual(indeterminate.recoveryExpectation, expectation)
        XCTAssertEqual(indeterminate.publicationSource, staging)
        XCTAssertNil(indeterminate.actualPublishedExpectation)
        XCTAssertEqual(
            try WorkspaceNoFollowItemInspector.inspectExact(at: staging),
            expectation
        )
        XCTAssertTrue(try isDirectory(staging.fileURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.destination.fileURL.path))
    }

    func testFileDestinationCollisionNeverOverwritesAndRetainsStaging() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let operations = WorkspaceFileOperations()
        let plan = try fixture.filePlan(operations: operations)
        let staging = try XCTUnwrap(plan.stagingLocation)
        try "racer".write(to: plan.destination.fileURL, atomically: false, encoding: .utf8)

        let indeterminate = try requireIndeterminate(operations.createFile(using: plan))

        XCTAssertEqual(indeterminate.reason, .destinationExists)
        XCTAssertEqual(indeterminate.recoveryState, .retained(staging))
        XCTAssertEqual(indeterminate.publicationSource, staging)
        XCTAssertNil(indeterminate.actualPublishedExpectation)
        XCTAssertEqual(
            try String(contentsOf: plan.destination.fileURL, encoding: .utf8),
            "racer"
        )
    }

    func testFolderDestinationCollisionNeverOverwritesAndRetainsStaging() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let operations = WorkspaceFileOperations()
        let plan = try fixture.folderPlan(operations: operations)
        let staging = try XCTUnwrap(plan.stagingLocation)
        try FileManager.default.createDirectory(
            at: plan.destination.fileURL,
            withIntermediateDirectories: false
        )
        let sentinel = plan.destination.fileURL.appendingPathComponent("sentinel")
        try "racer".write(to: sentinel, atomically: false, encoding: .utf8)

        let indeterminate = try requireIndeterminate(operations.createFolder(using: plan))

        XCTAssertEqual(indeterminate.reason, .destinationExists)
        XCTAssertEqual(indeterminate.recoveryState, .retained(staging))
        XCTAssertEqual(indeterminate.publicationSource, staging)
        XCTAssertNil(indeterminate.actualPublishedExpectation)
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "racer")
    }

    func testFileStagingCollisionDoesNotClaimOrOverwriteForeignEntry() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let operations = WorkspaceFileOperations()
        let plan = try fixture.filePlan(operations: operations)
        let staging = try XCTUnwrap(plan.stagingLocation)
        try "foreign".write(to: staging.fileURL, atomically: false, encoding: .utf8)
        var callbackCalled = false

        let outcome = operations.createFile(
            using: plan,
            recordingCreatedArtifact: { _ in callbackCalled = true }
        )

        XCTAssertEqual(outcome, .notCreated(.destinationExists))
        XCTAssertFalse(callbackCalled)
        XCTAssertEqual(try String(contentsOf: staging.fileURL, encoding: .utf8), "foreign")
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.destination.fileURL.path))
    }

    func testFolderStagingCollisionDoesNotClaimOrOverwriteForeignEntry() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let operations = WorkspaceFileOperations()
        let plan = try fixture.folderPlan(operations: operations)
        let staging = try XCTUnwrap(plan.stagingLocation)
        try FileManager.default.createDirectory(
            at: staging.fileURL,
            withIntermediateDirectories: false
        )
        let sentinel = staging.fileURL.appendingPathComponent("sentinel")
        try "foreign".write(to: sentinel, atomically: false, encoding: .utf8)
        var callbackCalled = false

        let outcome = operations.createFolder(
            using: plan,
            recordingCreatedArtifact: { _ in callbackCalled = true }
        )

        XCTAssertEqual(outcome, .notCreated(.destinationExists))
        XCTAssertFalse(callbackCalled)
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "foreign")
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.destination.fileURL.path))
    }

    func testFileParentSymlinkSubstitutionBeforePublishRetainsStagingAndWritesNowhereElse()
        throws
    {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let operations = WorkspaceFileOperations()
        let plan = try fixture.filePlan(operations: operations)
        let staging = try XCTUnwrap(plan.stagingLocation)
        let originalDrafts = fixture.url("drafts")
        let retiredDrafts = fixture.outsideURL("retired-drafts")
        let mutation = SynchronousMutation {
            try FileManager.default.moveItem(at: originalDrafts, to: retiredDrafts)
            try FileManager.default.createSymbolicLink(
                at: originalDrafts,
                withDestinationURL: fixture.outside
            )
        }
        let hooks = WorkspaceAnchoredFileSystem.Hooks(eventHandler: { event in
            if event == .willCommit(.exclusiveCreate) { mutation.run() }
        })

        let outcome = WorkspaceAnchoredItemCreator.createFile(
            using: plan,
            recordingCreatedArtifact: { _ in },
            hooks: hooks
        )

        try mutation.rethrowIfFailed()
        let indeterminate = try requireIndeterminate(outcome)
        XCTAssertEqual(indeterminate.recoveryState, .retained(staging))
        XCTAssertEqual(indeterminate.publicationSource, staging)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.outsideURL("post.md").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: retiredDrafts.appendingPathComponent("post.md").path
        ))
    }

    func testFolderParentSymlinkSubstitutionBeforePublishRetainsStagingAndWritesNowhereElse()
        throws
    {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let operations = WorkspaceFileOperations()
        let plan = try fixture.folderPlan(operations: operations)
        let staging = try XCTUnwrap(plan.stagingLocation)
        let originalDrafts = fixture.url("drafts")
        let retiredDrafts = fixture.outsideURL("retired-drafts")
        let mutation = SynchronousMutation {
            try FileManager.default.moveItem(at: originalDrafts, to: retiredDrafts)
            try FileManager.default.createSymbolicLink(
                at: originalDrafts,
                withDestinationURL: fixture.outside
            )
        }
        let hooks = WorkspaceItemCreationHooks(eventHandler: { event in
            if event == .willCreate { mutation.run() }
        })

        let outcome = WorkspaceAnchoredItemCreator.createDirectory(
            using: plan,
            recordingCreatedArtifact: { _ in },
            hooks: hooks
        )

        try mutation.rethrowIfFailed()
        let indeterminate = try requireIndeterminate(outcome)
        XCTAssertEqual(indeterminate.recoveryState, .retained(staging))
        XCTAssertEqual(indeterminate.publicationSource, staging)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.outsideURL("images").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: retiredDrafts.appendingPathComponent("images").path
        ))
    }

    func testFileSnapshotParentReplacementBeforeCreationRetainsStaging() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let operations = WorkspaceFileOperations()
        let plan = try fixture.filePlan(operations: operations)
        let staging = try XCTUnwrap(plan.stagingLocation)
        let retiredDrafts = fixture.outsideURL("retired-drafts")
        try FileManager.default.moveItem(at: fixture.url("drafts"), to: retiredDrafts)
        try FileManager.default.createDirectory(
            at: fixture.url("drafts"),
            withIntermediateDirectories: false
        )

        let indeterminate = try requireIndeterminate(operations.createFile(using: plan))

        XCTAssertEqual(indeterminate.reason, .destinationChanged)
        XCTAssertEqual(indeterminate.recoveryState, .retained(staging))
        XCTAssertEqual(indeterminate.publicationSource, staging)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.destination.fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: retiredDrafts.appendingPathComponent("post.md").path
        ))
    }

    func testFolderSnapshotParentReplacementBeforeCreationRetainsStaging() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let operations = WorkspaceFileOperations()
        let plan = try fixture.folderPlan(operations: operations)
        let staging = try XCTUnwrap(plan.stagingLocation)
        let retiredDrafts = fixture.outsideURL("retired-drafts")
        try FileManager.default.moveItem(at: fixture.url("drafts"), to: retiredDrafts)
        try FileManager.default.createDirectory(
            at: fixture.url("drafts"),
            withIntermediateDirectories: false
        )

        let indeterminate = try requireIndeterminate(operations.createFolder(using: plan))

        XCTAssertEqual(indeterminate.reason, .destinationChanged)
        XCTAssertEqual(indeterminate.recoveryState, .retained(staging))
        XCTAssertEqual(indeterminate.publicationSource, staging)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.destination.fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: retiredDrafts.appendingPathComponent("images").path
        ))
    }

    func testFileDestinationParentReplacementAtPublishKeepsActualIdentityObservable() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let operations = WorkspaceFileOperations()
        let plan = try fixture.filePlan(operations: operations)
        let staging = try XCTUnwrap(plan.stagingLocation)
        let retiredDrafts = fixture.outsideURL("retired-drafts")
        var recorded: WorkspacePreparedItemCreationArtifact?
        let mutation = SynchronousMutation {
            try FileManager.default.moveItem(at: fixture.url("drafts"), to: retiredDrafts)
            try FileManager.default.createDirectory(
                at: fixture.url("drafts"),
                withIntermediateDirectories: false
            )
        }
        let hooks = WorkspaceAnchoredFileSystem.Hooks(eventHandler: { event in
            if event == .willCommit(.exclusiveCreate) { mutation.run() }
        })

        let outcome = WorkspaceAnchoredItemCreator.createFile(
            using: plan,
            recordingCreatedArtifact: { recorded = $0 },
            hooks: hooks
        )

        try mutation.rethrowIfFailed()
        let indeterminate = try requireIndeterminate(outcome)
        let expectation = try XCTUnwrap(recorded?.expectation)
        XCTAssertEqual(indeterminate.createdExpectation, expectation)
        XCTAssertEqual(indeterminate.actualPublishedExpectation, expectation)
        XCTAssertEqual(indeterminate.recoveryState, .none)
        XCTAssertEqual(indeterminate.publicationSource, staging)
        XCTAssertEqual(
            try WorkspaceNoFollowItemInspector.inspectExact(at: plan.destination),
            expectation
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: retiredDrafts.appendingPathComponent("post.md").path
        ))
    }

    func testFolderDestinationParentReplacementAtPublishKeepsActualIdentityObservable() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let operations = WorkspaceFileOperations()
        let plan = try fixture.folderPlan(operations: operations)
        let staging = try XCTUnwrap(plan.stagingLocation)
        let retiredDrafts = fixture.outsideURL("retired-drafts")
        var recorded: WorkspacePreparedItemCreationArtifact?
        let mutation = SynchronousMutation {
            try FileManager.default.moveItem(at: fixture.url("drafts"), to: retiredDrafts)
            try FileManager.default.createDirectory(
                at: fixture.url("drafts"),
                withIntermediateDirectories: false
            )
        }
        let hooks = WorkspaceItemCreationHooks(eventHandler: { event in
            if event == .willCreate { mutation.run() }
        })

        let outcome = WorkspaceAnchoredItemCreator.createDirectory(
            using: plan,
            recordingCreatedArtifact: { recorded = $0 },
            hooks: hooks
        )

        try mutation.rethrowIfFailed()
        let indeterminate = try requireIndeterminate(outcome)
        let expectation = try XCTUnwrap(recorded?.expectation)
        XCTAssertEqual(indeterminate.createdExpectation, expectation)
        XCTAssertEqual(indeterminate.actualPublishedExpectation, expectation)
        XCTAssertEqual(indeterminate.recoveryState, .none)
        XCTAssertEqual(indeterminate.publicationSource, staging)
        XCTAssertEqual(
            try WorkspaceNoFollowItemInspector.inspectExact(at: plan.destination),
            expectation
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: retiredDrafts.appendingPathComponent("images").path
        ))
    }

    func testFilePublishedArtifactRemainsIdentifiedWhenParentEscapesAfterRename() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let operations = WorkspaceFileOperations()
        let plan = try fixture.filePlan(operations: operations)
        let staging = try XCTUnwrap(plan.stagingLocation)
        let escapedDrafts = fixture.outsideURL("published-drafts")
        var recorded: WorkspacePreparedItemCreationArtifact?
        let mutation = SynchronousMutation {
            try FileManager.default.moveItem(at: fixture.url("drafts"), to: escapedDrafts)
            try FileManager.default.createDirectory(
                at: fixture.url("drafts"),
                withIntermediateDirectories: false
            )
        }
        let hooks = WorkspaceAnchoredFileSystem.Hooks(eventHandler: { event in
            if event == .didCommit(.exclusiveCreate) { mutation.run() }
        })

        let outcome = WorkspaceAnchoredItemCreator.createFile(
            using: plan,
            recordingCreatedArtifact: { recorded = $0 },
            hooks: hooks
        )

        try mutation.rethrowIfFailed()
        let indeterminate = try requireIndeterminate(outcome)
        let expectation = try XCTUnwrap(recorded?.expectation)
        let escaped = try WorkspaceFileSystemLocation(
            fileURL: escapedDrafts.appendingPathComponent("post.md")
        )
        XCTAssertEqual(indeterminate.createdExpectation, expectation)
        XCTAssertEqual(indeterminate.actualPublishedExpectation, expectation)
        XCTAssertEqual(indeterminate.recoveryState, .none)
        XCTAssertEqual(indeterminate.publicationSource, staging)
        XCTAssertEqual(
            try WorkspaceNoFollowItemInspector.inspectExact(at: escaped),
            expectation
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.destination.fileURL.path))
    }

    func testFolderPublishedArtifactRemainsIdentifiedWhenParentEscapesAfterRename() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let operations = WorkspaceFileOperations()
        let plan = try fixture.folderPlan(operations: operations)
        let staging = try XCTUnwrap(plan.stagingLocation)
        let escapedDrafts = fixture.outsideURL("published-drafts")
        var recorded: WorkspacePreparedItemCreationArtifact?
        let mutation = SynchronousMutation {
            try FileManager.default.moveItem(at: fixture.url("drafts"), to: escapedDrafts)
            try FileManager.default.createDirectory(
                at: fixture.url("drafts"),
                withIntermediateDirectories: false
            )
        }
        let hooks = WorkspaceItemCreationHooks(eventHandler: { event in
            if event == .didCreateName { mutation.run() }
        })

        let outcome = WorkspaceAnchoredItemCreator.createDirectory(
            using: plan,
            recordingCreatedArtifact: { recorded = $0 },
            hooks: hooks
        )

        try mutation.rethrowIfFailed()
        let indeterminate = try requireIndeterminate(outcome)
        let expectation = try XCTUnwrap(recorded?.expectation)
        let escaped = try WorkspaceFileSystemLocation(
            fileURL: escapedDrafts.appendingPathComponent("images")
        )
        XCTAssertEqual(indeterminate.createdExpectation, expectation)
        XCTAssertEqual(indeterminate.actualPublishedExpectation, expectation)
        XCTAssertEqual(indeterminate.recoveryState, .none)
        XCTAssertEqual(indeterminate.publicationSource, staging)
        XCTAssertEqual(
            try WorkspaceNoFollowItemInspector.inspectExact(at: escaped),
            expectation
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.destination.fileURL.path))
    }

    func testFileStagingLeafSubstitutionReportsActualMovedIdentity() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let operations = WorkspaceFileOperations()
        let plan = try fixture.filePlan(operations: operations)
        let staging = try XCTUnwrap(plan.stagingLocation)
        let held = try fixture.location("held-created-file")
        var recorded: WorkspacePreparedItemCreationArtifact?
        let mutation = SynchronousMutation {
            try FileManager.default.moveItem(at: staging.fileURL, to: held.fileURL)
            try "substitute".write(
                to: staging.fileURL,
                atomically: false,
                encoding: .utf8
            )
        }
        let hooks = WorkspaceAnchoredFileSystem.Hooks(eventHandler: { event in
            if event == .willCommit(.exclusiveCreate) { mutation.run() }
        })

        let outcome = WorkspaceAnchoredItemCreator.createFile(
            using: plan,
            recordingCreatedArtifact: { recorded = $0 },
            hooks: hooks
        )

        try mutation.rethrowIfFailed()
        let indeterminate = try requireIndeterminate(outcome)
        let createdExpectation = try XCTUnwrap(recorded?.expectation)
        let actualExpectation = try WorkspaceNoFollowItemInspector.inspectExact(
            at: plan.destination
        )
        XCTAssertEqual(indeterminate.createdExpectation, createdExpectation)
        XCTAssertEqual(indeterminate.actualPublishedExpectation, actualExpectation)
        XCTAssertNotEqual(actualExpectation, createdExpectation)
        XCTAssertEqual(
            try WorkspaceNoFollowItemInspector.inspectExact(at: held),
            createdExpectation
        )
        XCTAssertEqual(
            try String(contentsOf: plan.destination.fileURL, encoding: .utf8),
            "substitute"
        )
    }

    func testFolderStagingLeafSubstitutionReportsActualMovedIdentity() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let operations = WorkspaceFileOperations()
        let plan = try fixture.folderPlan(operations: operations)
        let staging = try XCTUnwrap(plan.stagingLocation)
        let held = try fixture.location("held-created-folder")
        var recorded: WorkspacePreparedItemCreationArtifact?
        let mutation = SynchronousMutation {
            try FileManager.default.moveItem(at: staging.fileURL, to: held.fileURL)
            try FileManager.default.createDirectory(
                at: staging.fileURL,
                withIntermediateDirectories: false
            )
        }
        let hooks = WorkspaceItemCreationHooks(eventHandler: { event in
            if event == .willCreate { mutation.run() }
        })

        let outcome = WorkspaceAnchoredItemCreator.createDirectory(
            using: plan,
            recordingCreatedArtifact: { recorded = $0 },
            hooks: hooks
        )

        try mutation.rethrowIfFailed()
        let indeterminate = try requireIndeterminate(outcome)
        let createdExpectation = try XCTUnwrap(recorded?.expectation)
        let actualExpectation = try WorkspaceNoFollowItemInspector.inspectExact(
            at: plan.destination
        )
        XCTAssertEqual(indeterminate.createdExpectation, createdExpectation)
        XCTAssertEqual(indeterminate.actualPublishedExpectation, actualExpectation)
        XCTAssertNotEqual(actualExpectation, createdExpectation)
        XCTAssertEqual(
            try WorkspaceNoFollowItemInspector.inspectExact(at: held),
            createdExpectation
        )
    }

    func testFileTerminalReplacementCannotReturnDurableSuccess() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let operations = WorkspaceFileOperations()
        let plan = try fixture.filePlan(operations: operations)
        let held = try fixture.location("drafts/held-created-file")
        var recorded: WorkspacePreparedItemCreationArtifact?
        let mutation = SynchronousMutation {
            try FileManager.default.moveItem(at: plan.destination.fileURL, to: held.fileURL)
            try "replacement".write(
                to: plan.destination.fileURL,
                atomically: false,
                encoding: .utf8
            )
        }
        let hooks = WorkspaceAnchoredFileSystem.Hooks(eventHandler: { event in
            if event == .postflight { mutation.run() }
        })

        let outcome = WorkspaceAnchoredItemCreator.createFile(
            using: plan,
            recordingCreatedArtifact: { recorded = $0 },
            hooks: hooks
        )

        try mutation.rethrowIfFailed()
        let indeterminate = try requireIndeterminate(outcome)
        let expectation = try XCTUnwrap(recorded?.expectation)
        XCTAssertEqual(indeterminate.createdExpectation, expectation)
        XCTAssertEqual(indeterminate.actualPublishedExpectation, expectation)
        XCTAssertEqual(indeterminate.recoveryState, .none)
        XCTAssertEqual(
            try WorkspaceNoFollowItemInspector.inspectExact(at: held),
            expectation
        )
        XCTAssertNotEqual(
            try WorkspaceNoFollowItemInspector.inspectExact(at: plan.destination),
            expectation
        )
    }

    func testFolderTerminalReplacementCannotReturnDurableSuccess() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let operations = WorkspaceFileOperations()
        let plan = try fixture.folderPlan(operations: operations)
        let held = try fixture.location("drafts/held-created-folder")
        var recorded: WorkspacePreparedItemCreationArtifact?
        let mutation = SynchronousMutation {
            try FileManager.default.moveItem(at: plan.destination.fileURL, to: held.fileURL)
            try FileManager.default.createDirectory(
                at: plan.destination.fileURL,
                withIntermediateDirectories: false
            )
        }
        let hooks = WorkspaceItemCreationHooks(eventHandler: { event in
            if event == .postflight { mutation.run() }
        })

        let outcome = WorkspaceAnchoredItemCreator.createDirectory(
            using: plan,
            recordingCreatedArtifact: { recorded = $0 },
            hooks: hooks
        )

        try mutation.rethrowIfFailed()
        let indeterminate = try requireIndeterminate(outcome)
        let expectation = try XCTUnwrap(recorded?.expectation)
        XCTAssertEqual(indeterminate.createdExpectation, expectation)
        XCTAssertEqual(indeterminate.actualPublishedExpectation, expectation)
        XCTAssertEqual(indeterminate.recoveryState, .none)
        XCTAssertEqual(
            try WorkspaceNoFollowItemInspector.inspectExact(at: held),
            expectation
        )
        XCTAssertNotEqual(
            try WorkspaceNoFollowItemInspector.inspectExact(at: plan.destination),
            expectation
        )
    }

    func testFileStagingParentSyncFailureIsFailClosedBeforeCallback() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let operations = WorkspaceFileOperations()
        let plan = try fixture.filePlan(operations: operations)
        let staging = try XCTUnwrap(plan.stagingLocation)
        var callbackCalled = false
        let hooks = WorkspaceAnchoredFileSystem.Hooks(injectedFailure: { call in
            call == .syncCommittedDirectory ? .durabilityFailed : nil
        })

        let outcome = WorkspaceAnchoredItemCreator.createFile(
            using: plan,
            recordingCreatedArtifact: { _ in callbackCalled = true },
            hooks: hooks
        )

        let indeterminate = try requireIndeterminate(outcome)
        XCTAssertEqual(indeterminate.reason, .durabilityFailed)
        XCTAssertEqual(indeterminate.recoveryState, .retained(staging))
        XCTAssertFalse(callbackCalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.destination.fileURL.path))
    }

    func testFolderStagingParentSyncFailureIsFailClosedBeforeCallback() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let operations = WorkspaceFileOperations()
        let plan = try fixture.folderPlan(operations: operations)
        let staging = try XCTUnwrap(plan.stagingLocation)
        var callbackCalled = false
        let hooks = WorkspaceItemCreationHooks(injectedFailure: { call in
            call == .syncParent ? .durabilityFailed : nil
        })

        let outcome = WorkspaceAnchoredItemCreator.createDirectory(
            using: plan,
            recordingCreatedArtifact: { _ in callbackCalled = true },
            hooks: hooks
        )

        let indeterminate = try requireIndeterminate(outcome)
        XCTAssertEqual(indeterminate.reason, .durabilityFailed)
        XCTAssertEqual(indeterminate.recoveryState, .retained(staging))
        XCTAssertFalse(callbackCalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.destination.fileURL.path))
    }

    func testDirectorySourceMutationAtCloneBoundaryCannotReturnDurableSuccess() throws {
        WorkspaceDirectoryCloneSourceRegistry.shared.resetForTesting()
        defer { WorkspaceDirectoryCloneSourceRegistry.shared.resetForTesting() }
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let hooks = WorkspaceItemCreationHooks(eventHandler: { event in
            guard case let .willCloneDirectorySource(descriptor) = event else { return }
            XCTAssertEqual(
                Darwin.fchmod(
                    descriptor,
                    mode_t(S_IRWXU | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH)
                ),
                0
            )
        })

        let outcome = try WorkspaceAnchoredItemCreator.createDirectory(
            at: fixture.location("drafts/images"),
            expectingParent: fixture.draftsExpectation,
            hooks: hooks
        )

        XCTAssertEqual(outcome, .notCreated(.unreadable))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url("drafts/images").path))
    }

    func testDirectorySourceAllowedXattrMutationCannotReturnDurableSuccess() throws {
        WorkspaceDirectoryCloneSourceRegistry.shared.resetForTesting()
        defer { WorkspaceDirectoryCloneSourceRegistry.shared.resetForTesting() }
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let hooks = WorkspaceItemCreationHooks(eventHandler: { event in
            guard case let .willCloneDirectorySource(descriptor) = event else { return }
            let replacementValue = Data("mutated-macl-value".utf8)
            let result = replacementValue.withUnsafeBytes {
                Darwin.fsetxattr(
                    descriptor,
                    "com.apple.macl",
                    $0.baseAddress,
                    $0.count,
                    0,
                    0
                )
            }
            XCTAssertEqual(result, 0)
        })

        let outcome = try WorkspaceAnchoredItemCreator.createDirectory(
            at: fixture.location("drafts/images"),
            expectingParent: fixture.draftsExpectation,
            hooks: hooks
        )

        XCTAssertEqual(outcome, .notCreated(.unreadable))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url("drafts/images").path))
    }

    func testDirectoryCloneSourceIsUnlinkedBeforeUseAndDoesNotLeak() throws {
        WorkspaceDirectoryCloneSourceRegistry.shared.resetForTesting()
        defer { WorkspaceDirectoryCloneSourceRegistry.shared.resetForTesting() }
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let sourceCapture = DirectorySourceCapture()
        let hooks = WorkspaceItemCreationHooks(eventHandler: { event in
            guard case let .willUnlinkDirectorySource(_, sourceURL) = event else { return }
            sourceCapture.record(sourceURL)
        })

        _ = try requireCreated(WorkspaceAnchoredItemCreator.createDirectory(
            at: fixture.location("drafts/images"),
            expectingParent: fixture.draftsExpectation,
            hooks: hooks
        ))

        let sourceURL = try XCTUnwrap(sourceCapture.value)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
        WorkspaceDirectoryCloneSourceRegistry.shared.resetForTesting()
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    func testDirectoryCloneSourceReplacementBeforeUnlinkIsPreserved() throws {
        WorkspaceDirectoryCloneSourceRegistry.shared.resetForTesting()
        defer { WorkspaceDirectoryCloneSourceRegistry.shared.resetForTesting() }
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let replacement = DirectorySourceReplacement()
        defer { replacement.cleanUp() }
        let hooks = WorkspaceItemCreationHooks(eventHandler: { event in
            guard case let .willUnlinkDirectorySource(_, sourceURL) = event else { return }
            replacement.run(at: sourceURL)
        })

        let outcome = try WorkspaceAnchoredItemCreator.createDirectory(
            at: fixture.location("drafts/images"),
            expectingParent: fixture.draftsExpectation,
            hooks: hooks
        )

        try replacement.rethrowIfFailed()
        XCTAssertEqual(outcome, .notCreated(.unreadable))
        XCTAssertEqual(
            try String(contentsOf: XCTUnwrap(replacement.sentinelURL), encoding: .utf8),
            "replacement"
        )
        XCTAssertTrue(try isDirectory(XCTUnwrap(replacement.displacedSourceURL)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url("drafts/images").path))
    }

    func testDirectoryCloneSourceMovedInFinalRemovalGapIsNeverUsed() throws {
        WorkspaceDirectoryCloneSourceRegistry.shared.resetForTesting()
        defer { WorkspaceDirectoryCloneSourceRegistry.shared.resetForTesting() }
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let replacement = DirectorySourceReplacement()
        defer { replacement.cleanUp() }
        let hooks = WorkspaceItemCreationHooks(eventHandler: { event in
            guard case let .willRemoveVerifiedDirectorySource(_, sourceURL) = event else {
                return
            }
            replacement.run(at: sourceURL, includeSentinel: false)
        })

        let outcome = try WorkspaceAnchoredItemCreator.createDirectory(
            at: fixture.location("drafts/images"),
            expectingParent: fixture.draftsExpectation,
            hooks: hooks
        )

        try replacement.rethrowIfFailed()
        XCTAssertEqual(outcome, .notCreated(.unreadable))
        XCTAssertTrue(try isDirectory(XCTUnwrap(replacement.displacedSourceURL)))
        let originalSourceURL = try XCTUnwrap(replacement.originalSourceURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalSourceURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url("drafts/images").path))
    }

    func testDirectoryXattrMutationAfterPublishCannotReturnDurableSuccess() throws {
        WorkspaceDirectoryCloneSourceRegistry.shared.resetForTesting()
        defer { WorkspaceDirectoryCloneSourceRegistry.shared.resetForTesting() }
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let destinationURL = fixture.url("drafts/images")
        let mutation = SynchronousMutation {
            let descriptor = Darwin.open(
                destinationURL.path,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            guard descriptor >= 0 else { throw TestFailure.mutationFailed }
            defer { Darwin.close(descriptor) }
            let replacementValue = Data("post-publication-macl".utf8)
            let result = replacementValue.withUnsafeBytes {
                Darwin.fsetxattr(
                    descriptor,
                    "com.apple.macl",
                    $0.baseAddress,
                    $0.count,
                    0,
                    0
                )
            }
            guard result == 0 else { throw TestFailure.mutationFailed }
        }
        let hooks = WorkspaceItemCreationHooks(eventHandler: { event in
            if event == .didCreate { mutation.run() }
        })

        let outcome = try WorkspaceAnchoredItemCreator.createDirectory(
            at: fixture.location("drafts/images"),
            expectingParent: fixture.draftsExpectation,
            hooks: hooks
        )

        try mutation.rethrowIfFailed()
        let indeterminate = try requireIndeterminate(outcome)
        XCTAssertEqual(indeterminate.reason, .destinationChanged)
        XCTAssertEqual(
            indeterminate.actualPublishedExpectation,
            indeterminate.createdExpectation
        )
    }

    private func requireCreated(
        _ outcome: WorkspaceItemCreationOutcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> WorkspaceCreatedItem {
        guard case let .createdAndDurable(created) = outcome else {
            XCTFail("Expected createdAndDurable, got \(outcome)", file: file, line: line)
            throw TestFailure.unexpectedOutcome
        }
        return created
    }

    private func requireIndeterminate(
        _ outcome: WorkspaceItemCreationOutcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> WorkspaceIndeterminateItemCreation {
        guard case let .creationStateIndeterminate(indeterminate) = outcome else {
            XCTFail("Expected creationStateIndeterminate, got \(outcome)", file: file, line: line)
            throw TestFailure.unexpectedOutcome
        }
        return indeterminate
    }

    private func isDirectory(_ url: URL) throws -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
    }

    private func creationStagingEntries(in root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".plainsong-create-") }
    }
}

private extension WorkspaceAnchoredItemCreationTests {
    enum TestFailure: Error {
        case unexpectedOutcome
        case recordingFailed
        case mutationFailed
    }

    struct Fixture {
        let container: URL
        let root: URL
        let outside: URL
        let authority: WorkspaceFileSystemRootAuthority
        let draftsExpectation: WorkspaceItemMutationExpectation

        init() throws {
            container = FileManager.default.temporaryDirectory
                .appendingPathComponent("WorkspaceAnchoredItemCreationTests")
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            root = container.appendingPathComponent("workspace", isDirectory: true)
            outside = container.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("drafts", isDirectory: true),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: outside,
                withIntermediateDirectories: true
            )
            authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
            draftsExpectation = try WorkspaceNoFollowItemInspector.inspect(
                at: authority.location(relativePath: "drafts")
            )
        }

        func filePlan(
            operations: WorkspaceFileOperations
        ) throws -> WorkspaceItemCreationPlan {
            try operations.makeFileCreationPlan(
                named: "post.md",
                inDirectoryRelativePath: "drafts",
                rootAuthority: authority,
                expectingDirectory: draftsExpectation
            )
        }

        func folderPlan(
            operations: WorkspaceFileOperations
        ) throws -> WorkspaceItemCreationPlan {
            try operations.makeFolderCreationPlan(
                named: "images",
                inDirectoryRelativePath: "drafts",
                rootAuthority: authority,
                expectingDirectory: draftsExpectation
            )
        }

        func location(_ relativePath: String) throws -> WorkspaceFileSystemLocation {
            try authority.location(relativePath: relativePath)
        }

        func url(_ relativePath: String) -> URL {
            root.appendingPathComponent(relativePath)
        }

        func outsideURL(_ relativePath: String) -> URL {
            outside.appendingPathComponent(relativePath)
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: container)
        }
    }
}
