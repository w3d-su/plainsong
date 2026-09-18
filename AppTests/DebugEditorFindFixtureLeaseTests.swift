#if DEBUG
    @testable import Plainsong
    import XCTest

    final class DebugEditorFindFixtureLeaseTests: XCTestCase {
        func testCleanupFailsClosedWhenCapturedWorkspaceIsRenamedAway() throws {
            let fileManager = FileManager.default
            let fixture = try DebugEditorFindFixture.create(
                identifier: "f9-workspace-away-\(UUID().uuidString)",
                fileManager: fileManager
            )
            let heldWorkspace = fixture.workspaceURL
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "held-workspace-\(UUID().uuidString)",
                    isDirectory: true
                )
            try fileManager.moveItem(at: fixture.workspaceURL, to: heldWorkspace)
            defer {
                if fileManager.fileExists(atPath: heldWorkspace.path) {
                    try? fileManager.moveItem(
                        at: heldWorkspace,
                        to: fixture.workspaceURL
                    )
                }
                try? fixture.remove(fileManager: fileManager)
            }

            XCTAssertThrowsError(
                try fixture.remove(fileManager: fileManager)
            ) { error in
                guard case DebugEditorFindFixture.FixtureError
                    .capturedWorkspaceMissing = error
                else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
            XCTAssertTrue(fileManager.fileExists(atPath: heldWorkspace.path))

            try fileManager.moveItem(at: heldWorkspace, to: fixture.workspaceURL)
            try fixture.remove(fileManager: fileManager)
            XCTAssertFalse(fileManager.fileExists(atPath: fixture.workspaceURL.path))
        }

        func testCleanupFailsClosedWhenCapturedRootIsRenamedAway() throws {
            let fileManager = FileManager.default
            let testContainer = fileManager.temporaryDirectory
                .appendingPathComponent(
                    "EditorFindRootRename-\(UUID().uuidString)",
                    isDirectory: true
                )
            try fileManager.createDirectory(
                at: testContainer,
                withIntermediateDirectories: false
            )
            defer { try? fileManager.removeItem(at: testContainer) }
            let isolatedRoot = testContainer.appendingPathComponent(
                "PlainsongEditorFindUITests",
                isDirectory: true
            )
            let fixture = try DebugEditorFindFixture.create(
                identifier: "f9-root-away-\(UUID().uuidString)",
                fileManager: fileManager,
                fixturesRootOverride: isolatedRoot
            )
            let root = fixture.workspaceURL.deletingLastPathComponent()
            let heldRoot = testContainer.appendingPathComponent(
                "held-editor-find-root-\(UUID().uuidString)",
                isDirectory: true
            )
            try fileManager.moveItem(at: root, to: heldRoot)
            defer {
                if fileManager.fileExists(atPath: heldRoot.path) {
                    try? fileManager.moveItem(at: heldRoot, to: root)
                }
                try? fixture.remove(fileManager: fileManager)
            }

            XCTAssertThrowsError(
                try fixture.remove(fileManager: fileManager)
            ) { error in
                guard case DebugEditorFindFixture.FixtureError
                    .capturedFixturesRootMissing = error
                else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
            XCTAssertTrue(
                fileManager.fileExists(
                    atPath: heldRoot.appendingPathComponent(fixture.identifier).path
                )
            )

            try fileManager.moveItem(at: heldRoot, to: root)
            try fixture.remove(fileManager: fileManager)
            XCTAssertFalse(fileManager.fileExists(atPath: fixture.workspaceURL.path))
        }

        func testStaleSweepPreservesExpiredFixtureWhileLeaseOwnerIsLive() throws {
            let fileManager = FileManager.default
            let fixture = try DebugEditorFindFixture.create(
                identifier: "f9-live-lease-\(UUID().uuidString)",
                fileManager: fileManager
            )
            defer { try? fixture.remove(fileManager: fileManager) }
            let now = Date()
            try makeExpired(fixture.workspaceURL, relativeTo: now)

            try DebugEditorFindFixture.removeStaleFixtures(
                in: fixture.workspaceURL.deletingLastPathComponent(),
                excluding: "f9-different-current",
                fileManager: fileManager,
                now: now
            )

            XCTAssertTrue(fileManager.fileExists(atPath: fixture.workspaceURL.path))
        }

        func testStaleSweepReclaimsExpiredFixtureAfterLeaseOwnerExits() throws {
            let fileManager = FileManager.default
            var fixture: DebugEditorFindFixture.CreatedFixture? =
                try DebugEditorFindFixture.create(
                    identifier: "f9-released-lease-\(UUID().uuidString)",
                    fileManager: fileManager
                )
            let workspaceURL = try XCTUnwrap(fixture?.workspaceURL)
            let root = workspaceURL.deletingLastPathComponent()
            let now = Date()
            try makeExpired(workspaceURL, relativeTo: now)

            weak var releasedFixture: DebugEditorFindFixture.CreatedFixture?
            releasedFixture = fixture
            fixture = nil
            XCTAssertNil(releasedFixture)

            try DebugEditorFindFixture.removeStaleFixtures(
                in: root,
                excluding: "f9-different-current",
                fileManager: fileManager,
                now: now
            )

            XCTAssertFalse(fileManager.fileExists(atPath: workspaceURL.path))
        }

        func testStaleSweepRejectsReplacementAtReleasedFixturesPublishedName() throws {
            let fileManager = FileManager.default
            let testContainer = fileManager.temporaryDirectory
                .appendingPathComponent(
                    "EditorFindStaleReplacement-\(UUID().uuidString)",
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
            let identifier = "f9-stale-replacement-\(UUID().uuidString)"
            var fixture: DebugEditorFindFixture.CreatedFixture? =
                try DebugEditorFindFixture.create(
                    identifier: identifier,
                    fileManager: fileManager,
                    fixturesRootOverride: root
                )
            let workspaceURL = try XCTUnwrap(fixture?.workspaceURL)
            let heldWorkspace = testContainer.appendingPathComponent(
                "held-captured-workspace",
                isDirectory: true
            )
            let leaseURL = DebugEditorFindFixture.ownershipLeaseURL(
                for: identifier,
                in: root
            )
            try fileManager.moveItem(
                at: workspaceURL,
                to: heldWorkspace
            )
            try fileManager.createDirectory(
                at: workspaceURL,
                withIntermediateDirectories: false
            )
            let replacementSentinel = workspaceURL.appendingPathComponent(
                "replacement-sentinel"
            )
            try Data("preserve".utf8).write(to: replacementSentinel)
            let now = Date()
            try makeExpired(workspaceURL, relativeTo: now)

            weak var releasedFixture: DebugEditorFindFixture.CreatedFixture?
            releasedFixture = fixture
            fixture = nil
            XCTAssertNil(releasedFixture)

            try DebugEditorFindFixture.removeStaleFixtures(
                in: root,
                excluding: "f9-different-current",
                fileManager: fileManager,
                now: now
            )

            XCTAssertEqual(
                try String(
                    contentsOf: replacementSentinel,
                    encoding: .utf8
                ),
                "preserve"
            )
            XCTAssertTrue(fileManager.fileExists(atPath: heldWorkspace.path))
            XCTAssertTrue(fileManager.fileExists(atPath: leaseURL.path))

            try fileManager.removeItem(at: workspaceURL)
            try fileManager.moveItem(
                at: heldWorkspace,
                to: workspaceURL
            )
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
