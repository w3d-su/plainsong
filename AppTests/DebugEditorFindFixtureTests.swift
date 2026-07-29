#if DEBUG
    @testable import Plainsong
    import XCTest

    final class DebugEditorFindFixtureTests: XCTestCase {
        @MainActor
        func testAppLaunchFactoryUsesIsolatedPersistenceForEditorFindFixture() throws {
            let fixtureDefaults = try XCTUnwrap(
                UserDefaults(suiteName: DebugWorkspaceSearchFixture.userDefaultsSuiteName)
            )
            defer { DebugWorkspaceSearchFixture.clearIsolatedDefaults(fixtureDefaults) }

            let appState = makePlainsongAppState(environment: [
                DebugEditorFindFixture.environmentKey: "f9-launch-path",
            ])

            XCTAssertTrue(appState.lastOpenedFileStore is DebugLastOpenedFileStore)
            XCTAssertTrue(appState.recentItemStore is DebugRecentItemStore)
            XCTAssertFalse(appState.shouldRestoreLastOpenedFile)
            XCTAssertTrue(appState.recentItemURLs.isEmpty)
            XCTAssertNil(appState.currentDocument.fileURL)
        }

        func testFixtureProvidesExactAndOverflowingProductionQueries() throws {
            let fileManager = FileManager.default
            let identifier = "f9-unit-\(UUID().uuidString)"
            let workspaceURL = try DebugEditorFindFixture.create(
                identifier: identifier,
                fileManager: fileManager
            )
            defer { try? fileManager.removeItem(at: workspaceURL) }

            let source = try String(
                contentsOf: workspaceURL.appendingPathComponent("editor-find.md"),
                encoding: .utf8
            )
            XCTAssertEqual(source.components(separatedBy: "needle").count - 1, 3)
            XCTAssertEqual(source.components(separatedBy: "x").count - 1, 10001)
        }

        func testRemoveStaleFixturesPreservesCurrentRecentUnrelatedAndSymlink() throws {
            let fileManager = FileManager.default
            let root = fileManager.temporaryDirectory
                .appendingPathComponent(
                    "EditorFindFixtureCleanup-\(UUID().uuidString)",
                    isDirectory: true
                )
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: root) }

            let current = try makeDirectory(named: "f9-current", under: root)
            let stale = try makeDirectory(named: "f9-stale", under: root)
            let recent = try makeDirectory(named: "f9-recent", under: root)
            let unrelated = try makeDirectory(named: "other-stale", under: root)
            let symlink = root.appendingPathComponent("f9-link")
            try fileManager.createSymbolicLink(at: symlink, withDestinationURL: unrelated)

            let now = Date(timeIntervalSinceReferenceDate: 10000)
            let expired = now.addingTimeInterval(-DebugEditorFindFixture.staleFixtureAge - 1)
            for url in [stale, unrelated] {
                try fileManager.setAttributes(
                    [.modificationDate: expired],
                    ofItemAtPath: url.path
                )
            }
            try fileManager.setAttributes(
                [.modificationDate: now],
                ofItemAtPath: recent.path
            )

            try DebugEditorFindFixture.removeStaleFixtures(
                in: root,
                excluding: current.lastPathComponent,
                fileManager: fileManager,
                now: now
            )

            XCTAssertTrue(fileManager.fileExists(atPath: current.path))
            XCTAssertFalse(fileManager.fileExists(atPath: stale.path))
            XCTAssertTrue(fileManager.fileExists(atPath: recent.path))
            XCTAssertTrue(fileManager.fileExists(atPath: unrelated.path))
            XCTAssertTrue(fileManager.fileExists(atPath: symlink.path))
        }

        func testRemoveStaleFixturesRejectsSymlinkRootWithoutTouchingTarget() throws {
            let fileManager = FileManager.default
            let container = fileManager.temporaryDirectory
                .appendingPathComponent(
                    "EditorFindFixtureRootLink-\(UUID().uuidString)",
                    isDirectory: true
                )
            let target = container.appendingPathComponent("target", isDirectory: true)
            let rootLink = container.appendingPathComponent("fixtures", isDirectory: true)
            try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: container) }

            let stale = try makeDirectory(named: "f9-stale", under: target)
            try fileManager.createSymbolicLink(at: rootLink, withDestinationURL: target)

            XCTAssertThrowsError(
                try DebugEditorFindFixture.removeStaleFixtures(
                    in: rootLink,
                    excluding: "f9-current",
                    fileManager: fileManager,
                    now: Date.distantFuture
                )
            ) { error in
                guard case DebugEditorFindFixture.FixtureError.unsafeFixturesRoot = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
            XCTAssertTrue(fileManager.fileExists(atPath: stale.path))
            XCTAssertTrue(fileManager.fileExists(atPath: rootLink.path))
        }

        private func makeDirectory(named name: String, under root: URL) throws -> URL {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: false
            )
            return url
        }
    }
#endif
