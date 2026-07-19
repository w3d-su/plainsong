@testable import WorkspaceKit
import XCTest

final class WorkspaceAnchoredItemTrashTests: XCTestCase {
    func testTrashStagesUnderUniqueHiddenRootNameAndProvesResult() async throws {
        let fixture = try TrashFixture()
        let source = try fixture.makeFile("post.md", text: "post")
        let expectation = try WorkspaceNoFollowItemInspector.inspect(at: source)
        let recycler = ControlledRecycler(trashRoot: fixture.trashRoot)
        let operations = WorkspaceFileOperations(recycler: recycler)
        let stagingPlan = try operations.makeTrashStagingPlan(
            rootAuthority: fixture.authority
        )

        let outcome = await operations.trash(
            source,
            expecting: expectation,
            sourceParentExpectation: fixture.authority.directoryMutationExpectation,
            stagingPlan: stagingPlan
        )

        guard case let .trashed(result) = outcome else {
            return XCTFail("Expected proven Trash result, got \(outcome)")
        }
        let recycledURL = try XCTUnwrap(recycler.recycledURLs.first)
        XCTAssertEqual(stagingPlan.rootParentExpectation, fixture.authority.directoryMutationExpectation)
        XCTAssertEqual(recycledURL, stagingPlan.stagingLocation.fileURL)
        XCTAssertTrue(recycledURL.lastPathComponent.hasPrefix(".plainsong-trash-"))
        XCTAssertEqual(
            recycledURL.deletingLastPathComponent(),
            fixture.authority.canonicalRootURL
        )
        XCTAssertEqual(result.source, source)
        XCTAssertEqual(result.expectation, expectation)
        XCTAssertEqual(result.stagingCleanupState, .removed)
        XCTAssertEqual(try fixture.noFollowExpectation(at: result.trashURL), expectation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.fileURL.path))
        XCTAssertFalse(try fixture.hasTrashStagingDirectory())
    }

    func testRecyclerFailureRetainsExactStagedIdentityWithoutUnsafeReverseRename() async throws {
        let fixture = try TrashFixture()
        let source = try fixture.makeFile("post.md", text: "post")
        let expectation = try WorkspaceNoFollowItemInspector.inspect(at: source)
        let recycler = ControlledRecycler(trashRoot: fixture.trashRoot, failure: RecyclerError.rejected)
        let operations = WorkspaceFileOperations(recycler: recycler)
        let stagingPlan = try operations.makeTrashStagingPlan(
            rootAuthority: fixture.authority
        )

        let outcome = await operations.trash(
            source,
            expecting: expectation,
            sourceParentExpectation: fixture.authority.directoryMutationExpectation,
            stagingPlan: stagingPlan
        )

        guard case let .trashStateIndeterminate(result) = outcome else {
            return XCTFail("Expected retained recovery state, got \(outcome)")
        }
        let stagedLocation = try XCTUnwrap(result.recoveryLocation)
        XCTAssertEqual(stagedLocation, stagingPlan.stagingLocation)
        XCTAssertEqual(result.source, source)
        XCTAssertEqual(result.expectation, expectation)
        XCTAssertEqual(result.reason, .recyclerFailed)
        XCTAssertEqual(result.stagingCleanupState, .removalIndeterminate(stagedLocation))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.fileURL.path))
        XCTAssertEqual(try WorkspaceNoFollowItemInspector.inspect(at: stagedLocation), expectation)
        XCTAssertEqual(try String(contentsOf: stagedLocation.fileURL, encoding: .utf8), "post")
        XCTAssertTrue(try fixture.hasTrashStagingDirectory())
    }

    func testTrashRefusesStaleSnapshotBeforeCallingRecycler() async throws {
        let fixture = try TrashFixture()
        let source = try fixture.makeFile("post.md", text: "expected")
        let expectation = try WorkspaceNoFollowItemInspector.inspect(at: source)
        try FileManager.default.removeItem(at: source.fileURL)
        try "replacement".write(to: source.fileURL, atomically: false, encoding: .utf8)
        let recycler = ControlledRecycler(trashRoot: fixture.trashRoot)
        let operations = WorkspaceFileOperations(recycler: recycler)
        let stagingPlan = try operations.makeTrashStagingPlan(
            rootAuthority: fixture.authority
        )

        let outcome = await operations.trash(
            source,
            expecting: expectation,
            sourceParentExpectation: fixture.authority.directoryMutationExpectation,
            stagingPlan: stagingPlan
        )

        guard case let .notTrashed(result) = outcome,
              result.reason == .sourceChanged
        else {
            return XCTFail("Expected stale snapshot rejection, got \(outcome)")
        }
        XCTAssertEqual(result.stagingCleanupState, .notCreated)
        XCTAssertTrue(recycler.recycledURLs.isEmpty)
        XCTAssertEqual(try String(contentsOf: source.fileURL, encoding: .utf8), "replacement")
    }

    func testTrashMovesSymbolicLinkLexicallyAndLeavesTargetUntouched() async throws {
        let fixture = try TrashFixture()
        let target = try fixture.makeFile("target.md", text: "target")
        let source = try fixture.location("alias.md")
        try FileManager.default.createSymbolicLink(
            atPath: source.fileURL.path,
            withDestinationPath: target.fileURL.lastPathComponent
        )
        let expectation = try WorkspaceNoFollowItemInspector.inspect(at: source)
        let recycler = ControlledRecycler(trashRoot: fixture.trashRoot)
        let operations = WorkspaceFileOperations(recycler: recycler)
        let stagingPlan = try operations.makeTrashStagingPlan(
            rootAuthority: fixture.authority
        )

        let outcome = await operations.trash(
            source,
            expecting: expectation,
            sourceParentExpectation: fixture.authority.directoryMutationExpectation,
            stagingPlan: stagingPlan
        )

        guard case let .trashed(result) = outcome else {
            return XCTFail("Expected lexical symlink Trash, got \(outcome)")
        }
        XCTAssertEqual(expectation.kind, .symbolicLink)
        XCTAssertEqual(try fixture.noFollowExpectation(at: result.trashURL), expectation)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: result.trashURL.path),
            "target.md"
        )
        XCTAssertEqual(try String(contentsOf: target.fileURL, encoding: .utf8), "target")
    }

    func testRecyclerResultIdentityMismatchIsIndeterminate() async throws {
        let fixture = try TrashFixture()
        let source = try fixture.makeFile("post.md", text: "expected")
        let expectation = try WorkspaceNoFollowItemInspector.inspect(at: source)
        let recycler = ControlledRecycler(
            trashRoot: fixture.trashRoot,
            replacesResultAfterMove: true
        )
        let operations = WorkspaceFileOperations(recycler: recycler)
        let stagingPlan = try operations.makeTrashStagingPlan(
            rootAuthority: fixture.authority
        )

        let outcome = await operations.trash(
            source,
            expecting: expectation,
            sourceParentExpectation: fixture.authority.directoryMutationExpectation,
            stagingPlan: stagingPlan
        )

        guard case let .trashStateIndeterminate(result) = outcome else {
            return XCTFail("Expected unproven recycler result, got \(outcome)")
        }
        XCTAssertEqual(result.reason, .sourceChanged)
        XCTAssertNil(result.recoveryLocation)
        XCTAssertNotNil(result.reportedTrashURL)
    }

    func testFileReferenceRecyclerNeverTrashesAStagingPathReplacement() async throws {
        let fixture = try TrashFixture()
        let source = try fixture.makeFile("post.md", text: "expected")
        let expectation = try WorkspaceNoFollowItemInspector.inspect(at: source)
        let recycler = ControlledRecycler(
            trashRoot: fixture.trashRoot,
            replacesStagingBeforeMove: true
        )
        let operations = WorkspaceFileOperations(recycler: recycler)
        let stagingPlan = try operations.makeTrashStagingPlan(
            rootAuthority: fixture.authority
        )

        let outcome = await operations.trash(
            source,
            expecting: expectation,
            sourceParentExpectation: fixture.authority.directoryMutationExpectation,
            stagingPlan: stagingPlan
        )

        guard case let .trashStateIndeterminate(result) = outcome else {
            return XCTFail("Expected a staged-replacement recovery state, got \(outcome)")
        }
        let stagedURL = try XCTUnwrap(recycler.recycledURLs.first)
        let reportedTrashURL = try XCTUnwrap(result.reportedTrashURL)
        let actualStagedExpectation = try fixture.noFollowExpectation(at: stagedURL)
        XCTAssertEqual(try fixture.noFollowExpectation(at: reportedTrashURL), expectation)
        XCTAssertEqual(
            try String(contentsOf: reportedTrashURL, encoding: .utf8),
            "expected"
        )
        XCTAssertEqual(
            try String(contentsOf: stagedURL, encoding: .utf8),
            "replacement"
        )
        XCTAssertEqual(result.actualStagedExpectation, actualStagedExpectation)
        XCTAssertEqual(
            result.stagingCleanupState,
            try .removalIndeterminate(fixture.location(stagedURL.lastPathComponent))
        )
    }

    func testTrashRejectsStagingPlanFromDifferentRetainedRoot() async throws {
        let fixture = try TrashFixture()
        let otherFixture = try TrashFixture()
        let source = try fixture.makeFile("post.md", text: "expected")
        let expectation = try WorkspaceNoFollowItemInspector.inspect(at: source)
        let recycler = ControlledRecycler(trashRoot: fixture.trashRoot)
        let operations = WorkspaceFileOperations(recycler: recycler)
        let stagingPlan = try operations.makeTrashStagingPlan(
            rootAuthority: otherFixture.authority
        )

        let outcome = await operations.trash(
            source,
            expecting: expectation,
            sourceParentExpectation: fixture.authority.directoryMutationExpectation,
            stagingPlan: stagingPlan
        )

        guard case let .notTrashed(result) = outcome else {
            return XCTFail("Expected mismatched-plan rejection, got \(outcome)")
        }
        XCTAssertEqual(result.reason, .differentRootAuthority)
        XCTAssertEqual(result.stagingCleanupState, .notCreated)
        XCTAssertEqual(try String(contentsOf: source.fileURL, encoding: .utf8), "expected")
        XCTAssertTrue(recycler.recycledURLs.isEmpty)
    }

    func testTrashRejectsStagingPlanWithMismatchedRootParentExpectation() async throws {
        let fixture = try TrashFixture()
        let source = try fixture.makeFile("post.md", text: "expected")
        let expectation = try WorkspaceNoFollowItemInspector.inspect(at: source)
        let recycler = ControlledRecycler(trashRoot: fixture.trashRoot)
        let operations = WorkspaceFileOperations(recycler: recycler)
        let validPlan = try operations.makeTrashStagingPlan(
            rootAuthority: fixture.authority
        )
        let mismatchedPlan = WorkspaceItemTrashStagingPlan(
            stagingLocation: validPlan.stagingLocation,
            rootParentExpectation: expectation
        )

        let outcome = await operations.trash(
            source,
            expecting: expectation,
            sourceParentExpectation: fixture.authority.directoryMutationExpectation,
            stagingPlan: mismatchedPlan
        )

        guard case let .notTrashed(result) = outcome else {
            return XCTFail("Expected parent-expectation rejection, got \(outcome)")
        }
        XCTAssertEqual(result.reason, .destinationChanged)
        XCTAssertEqual(result.stagingCleanupState, .notCreated)
        XCTAssertEqual(try String(contentsOf: source.fileURL, encoding: .utf8), "expected")
        XCTAssertTrue(recycler.recycledURLs.isEmpty)
    }

    func testTrashDoesNotOverwriteStagingRacerCreatedAfterPlanning() async throws {
        let fixture = try TrashFixture()
        let source = try fixture.makeFile("post.md", text: "expected")
        let expectation = try WorkspaceNoFollowItemInspector.inspect(at: source)
        let recycler = ControlledRecycler(trashRoot: fixture.trashRoot)
        let operations = WorkspaceFileOperations(recycler: recycler)
        let stagingPlan = try operations.makeTrashStagingPlan(
            rootAuthority: fixture.authority
        )
        try "racer".write(
            to: stagingPlan.stagingLocation.fileURL,
            atomically: false,
            encoding: .utf8
        )

        let outcome = await operations.trash(
            source,
            expecting: expectation,
            sourceParentExpectation: fixture.authority.directoryMutationExpectation,
            stagingPlan: stagingPlan
        )

        guard case let .notTrashed(result) = outcome else {
            return XCTFail("Expected exclusive staging rejection, got \(outcome)")
        }
        XCTAssertEqual(result.reason, .destinationExists)
        XCTAssertEqual(result.stagingCleanupState, .notCreated)
        XCTAssertEqual(try String(contentsOf: source.fileURL, encoding: .utf8), "expected")
        XCTAssertEqual(
            try String(contentsOf: stagingPlan.stagingLocation.fileURL, encoding: .utf8),
            "racer"
        )
        XCTAssertTrue(recycler.recycledURLs.isEmpty)
    }

    func testReusedPlanCannotOverwriteAnItemRetainedByAnEarlierAttempt() async throws {
        let fixture = try TrashFixture()
        let firstSource = try fixture.makeFile("first.md", text: "first")
        let secondSource = try fixture.makeFile("second.md", text: "second")
        let firstExpectation = try WorkspaceNoFollowItemInspector.inspect(at: firstSource)
        let secondExpectation = try WorkspaceNoFollowItemInspector.inspect(at: secondSource)
        let recycler = ControlledRecycler(
            trashRoot: fixture.trashRoot,
            failure: RecyclerError.rejected
        )
        let operations = WorkspaceFileOperations(recycler: recycler)
        let stagingPlan = try operations.makeTrashStagingPlan(
            rootAuthority: fixture.authority
        )

        let firstOutcome = await operations.trash(
            firstSource,
            expecting: firstExpectation,
            sourceParentExpectation: fixture.authority.directoryMutationExpectation,
            stagingPlan: stagingPlan
        )
        guard case .trashStateIndeterminate = firstOutcome else {
            return XCTFail("Expected first attempt to retain the staged item, got \(firstOutcome)")
        }

        let secondOutcome = await operations.trash(
            secondSource,
            expecting: secondExpectation,
            sourceParentExpectation: fixture.authority.directoryMutationExpectation,
            stagingPlan: stagingPlan
        )
        guard case let .notTrashed(result) = secondOutcome else {
            return XCTFail("Expected reused-plan rejection, got \(secondOutcome)")
        }
        XCTAssertEqual(result.reason, .destinationExists)
        XCTAssertEqual(
            try WorkspaceNoFollowItemInspector.inspect(at: stagingPlan.stagingLocation),
            firstExpectation
        )
        XCTAssertEqual(
            try String(contentsOf: stagingPlan.stagingLocation.fileURL, encoding: .utf8),
            "first"
        )
        XCTAssertEqual(try String(contentsOf: secondSource.fileURL, encoding: .utf8), "second")
        XCTAssertEqual(recycler.recycledURLs, [stagingPlan.stagingLocation.fileURL])
    }
}

private enum RecyclerError: Error {
    case rejected
}

private final class ControlledRecycler: WorkspaceItemRecycling, @unchecked Sendable {
    private let lock = NSLock()
    private let trashRoot: URL
    private let failure: Error?
    private let replacesStagingBeforeMove: Bool
    private let replacesResultAfterMove: Bool
    private var recordedURLs: [URL] = []

    var recycledURLs: [URL] {
        lock.withLock { recordedURLs }
    }

    init(
        trashRoot: URL,
        failure: Error? = nil,
        replacesStagingBeforeMove: Bool = false,
        replacesResultAfterMove: Bool = false
    ) {
        self.trashRoot = trashRoot
        self.failure = failure
        self.replacesStagingBeforeMove = replacesStagingBeforeMove
        self.replacesResultAfterMove = replacesResultAfterMove
    }

    func recycle(
        _ requests: [WorkspaceItemRecycleRequest]
    ) async throws -> [UUID: URL] {
        lock.withLock {
            recordedURLs.append(contentsOf: requests.map(\.lexicalURL))
        }
        if let failure {
            throw failure
        }
        var results: [UUID: URL] = [:]
        for request in requests {
            if replacesStagingBeforeMove {
                let heldURL = trashRoot.appendingPathComponent("held-\(UUID().uuidString)")
                try FileManager.default.moveItem(at: request.lexicalURL, to: heldURL)
                try "replacement".write(
                    to: request.lexicalURL,
                    atomically: false,
                    encoding: .utf8
                )
            }
            let resolvedURL = try request.resolvedFileURL()
            let destination = trashRoot.appendingPathComponent(
                request.lexicalURL.lastPathComponent
            )
            try FileManager.default.moveItem(at: resolvedURL, to: destination)
            results[request.id] = destination
            if replacesResultAfterMove {
                try FileManager.default.removeItem(at: destination)
                try "racer".write(to: destination, atomically: false, encoding: .utf8)
            }
        }
        return results
    }
}

private final class TrashFixture {
    let root: URL
    let trashRoot: URL
    let authority: WorkspaceFileSystemRootAuthority

    init() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceAnchoredItemTrashTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        root = container.appendingPathComponent("workspace", isDirectory: true)
        trashRoot = container.appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trashRoot, withIntermediateDirectories: true)
        authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
    }

    deinit {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    func location(_ relativePath: String) throws -> WorkspaceFileSystemLocation {
        try authority.location(relativePath: relativePath)
    }

    func makeFile(_ relativePath: String, text: String) throws -> WorkspaceFileSystemLocation {
        let location = try location(relativePath)
        try text.write(to: location.fileURL, atomically: false, encoding: .utf8)
        return location
    }

    func noFollowExpectation(at url: URL) throws -> WorkspaceItemMutationExpectation {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return WorkspaceItemMutationExpectation(
            identity: .init(device: UInt64(status.st_dev), inode: UInt64(status.st_ino)),
            kind: WorkspaceFileSystemItemKind(mode: status.st_mode)
        )
    }

    func hasTrashStagingDirectory() throws -> Bool {
        try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).contains { $0.lastPathComponent.hasPrefix(".plainsong-trash-") }
    }
}
