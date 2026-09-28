#if DEBUG
    @testable import Plainsong
    import XCTest

    final class DebugEditorFindFixtureLeaseRecoveryTests: XCTestCase {
        private enum TestError: Error {
            case sourceWriteFailed
        }

        func testPreWorkspaceLeaseBlocksLiveDuplicateAndRecoversAfterOwnerExit() throws {
            let fileManager = FileManager.default
            let testContainer = fileManager.temporaryDirectory
                .appendingPathComponent(
                    "EditorFindPreWorkspaceLease-\(UUID().uuidString)",
                    isDirectory: true
                )
            let root = testContainer.appendingPathComponent(
                "PlainsongEditorFindUITests",
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            defer { try? fileManager.removeItem(at: testContainer) }
            let identifier = "f9-pre-workspace-\(UUID().uuidString)"
            let workspaceURL = root.appendingPathComponent(
                identifier,
                isDirectory: true
            )
            var preWorkspaceLease: DebugEditorFindFixtureLease? =
                try DebugEditorFindFixtureLease.create(
                    at: DebugEditorFindFixture.ownershipLeaseURL(
                        for: identifier,
                        in: root
                    )
                )

            XCTAssertThrowsError(
                try DebugEditorFindFixture.create(
                    identifier: identifier,
                    fileManager: fileManager,
                    fixturesRootOverride: root
                )
            ) { error in
                guard case DebugEditorFindFixture.FixtureError
                    .fixtureAlreadyExists = error
                else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
            XCTAssertFalse(fileManager.fileExists(atPath: workspaceURL.path))

            preWorkspaceLease = nil
            let recoveredFixture = try DebugEditorFindFixture.create(
                identifier: identifier,
                fileManager: fileManager,
                fixturesRootOverride: root
            )
            try recoveredFixture.remove(fileManager: fileManager)

            XCTAssertNil(preWorkspaceLease)
            XCTAssertFalse(fileManager.fileExists(atPath: workspaceURL.path))
        }

        func testStaleSweepPreservesLiveAndReclaimsReleasedPreWorkspaceLease() throws {
            let fileManager = FileManager.default
            let testContainer = fileManager.temporaryDirectory
                .appendingPathComponent(
                    "EditorFindOrphanLease-\(UUID().uuidString)",
                    isDirectory: true
                )
            let root = testContainer.appendingPathComponent(
                "PlainsongEditorFindUITests",
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            defer { try? fileManager.removeItem(at: testContainer) }
            let identifier = "f9-orphan-lease-\(UUID().uuidString)"
            let leaseURL = DebugEditorFindFixture.ownershipLeaseURL(
                for: identifier,
                in: root
            )
            var lease: DebugEditorFindFixtureLease? =
                try DebugEditorFindFixtureLease.create(at: leaseURL)
            let now = Date()
            try makeExpired(leaseURL, relativeTo: now)

            try DebugEditorFindFixture.removeStaleFixtures(
                in: root,
                excluding: "f9-different-current",
                fileManager: fileManager,
                now: now
            )
            XCTAssertTrue(fileManager.fileExists(atPath: leaseURL.path))

            lease = nil
            try DebugEditorFindFixture.removeStaleFixtures(
                in: root,
                excluding: "f9-different-current",
                fileManager: fileManager,
                now: now
            )

            XCTAssertNil(lease)
            XCTAssertFalse(fileManager.fileExists(atPath: leaseURL.path))
        }

        func testFailedCreationDoesNotLeaseOrSweepPreexistingUnleasedWorkspace() throws {
            let fileManager = FileManager.default
            let testContainer = fileManager.temporaryDirectory
                .appendingPathComponent(
                    "EditorFindOccupiedUnleased-\(UUID().uuidString)",
                    isDirectory: true
                )
            let root = testContainer.appendingPathComponent(
                "PlainsongEditorFindUITests",
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            defer { try? fileManager.removeItem(at: testContainer) }
            let identifier = "f9-occupied-unleased-\(UUID().uuidString)"
            let workspaceURL = root.appendingPathComponent(
                identifier,
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: workspaceURL,
                withIntermediateDirectories: false
            )
            let sentinel = workspaceURL.appendingPathComponent("sentinel")
            try Data("preserve".utf8).write(to: sentinel)
            let leaseURL = DebugEditorFindFixture.ownershipLeaseURL(
                for: identifier,
                in: root
            )
            let now = Date()
            try makeExpired(workspaceURL, relativeTo: now)

            XCTAssertThrowsError(
                try DebugEditorFindFixture.create(
                    identifier: identifier,
                    fileManager: fileManager,
                    now: now,
                    fixturesRootOverride: root
                )
            ) { error in
                guard case DebugEditorFindFixture.FixtureError
                    .fixtureAlreadyExists = error
                else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
            XCTAssertFalse(fileManager.fileExists(atPath: leaseURL.path))

            try DebugEditorFindFixture.removeStaleFixtures(
                in: root,
                excluding: "f9-different-current",
                fileManager: fileManager,
                now: now
            )

            XCTAssertEqual(
                try String(contentsOf: sentinel, encoding: .utf8),
                "preserve"
            )
            XCTAssertFalse(fileManager.fileExists(atPath: leaseURL.path))
        }

        func testFailedCreationRetainsLeaseWhenWorkspaceRemovalCannotBeVerified() throws {
            let fileManager = FileManager.default
            let testContainer = fileManager.temporaryDirectory
                .appendingPathComponent(
                    "EditorFindFailedCreation-\(UUID().uuidString)",
                    isDirectory: true
                )
            let root = testContainer.appendingPathComponent(
                "PlainsongEditorFindUITests",
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: testContainer,
                withIntermediateDirectories: false
            )
            defer { try? fileManager.removeItem(at: testContainer) }
            let identifier = "f9-failed-creation-\(UUID().uuidString)"
            let workspaceURL = root.appendingPathComponent(
                identifier,
                isDirectory: true
            )
            let heldWorkspace = testContainer.appendingPathComponent(
                "held-failed-workspace",
                isDirectory: true
            )
            let leaseURL = DebugEditorFindFixture.ownershipLeaseURL(
                for: identifier,
                in: root
            )

            XCTAssertThrowsError(
                try DebugEditorFindFixture.create(
                    identifier: identifier,
                    fileManager: fileManager,
                    fixturesRootOverride: root,
                    sourceWriter: { _, sourceURL in
                        try fileManager.moveItem(
                            at: sourceURL.deletingLastPathComponent(),
                            to: heldWorkspace
                        )
                        throw TestError.sourceWriteFailed
                    }
                )
            ) { error in
                guard case TestError.sourceWriteFailed = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
            XCTAssertTrue(fileManager.fileExists(atPath: heldWorkspace.path))
            XCTAssertTrue(fileManager.fileExists(atPath: leaseURL.path))

            try fileManager.moveItem(at: heldWorkspace, to: workspaceURL)
            let now = Date()
            try makeExpired(workspaceURL, relativeTo: now)
            try DebugEditorFindFixture.removeStaleFixtures(
                in: root,
                excluding: "f9-different-current",
                fileManager: fileManager,
                now: now
            )

            XCTAssertFalse(fileManager.fileExists(atPath: workspaceURL.path))
            XCTAssertFalse(fileManager.fileExists(atPath: leaseURL.path))
        }

        private func makeExpired(_ url: URL, relativeTo now: Date) throws {
            try FileManager.default.setAttributes(
                [
                    .modificationDate:
                        now.addingTimeInterval(
                            -DebugEditorFindFixture.staleFixtureAge - 1
                        ),
                ],
                ofItemAtPath: url.path
            )
        }
    }
#endif
