#if DEBUG
    @testable import Plainsong
    import XCTest

    final class DebugEditorFindFixtureStaleTests: XCTestCase {
        func testRemoveStaleFixturesPreservesUnleasedCurrentRecentUnrelatedAndSymlink() throws {
            let fileManager = FileManager.default
            let root = fileManager.temporaryDirectory
                .appendingPathComponent(
                    "EditorFindFixtureCleanup-\(UUID().uuidString)",
                    isDirectory: true
                )
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: root) }

            let current = try makeStaleTestDirectory(named: "f9-current", under: root)
            let stale = try makeStaleTestDirectory(named: "f9-stale", under: root)
            let recent = try makeStaleTestDirectory(named: "f9-recent", under: root)
            let unrelated = try makeStaleTestDirectory(named: "other-stale", under: root)
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
            XCTAssertTrue(
                fileManager.fileExists(atPath: stale.path),
                "A legacy directory without a lease has no provable ownership"
            )
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

            let stale = try makeStaleTestDirectory(named: "f9-stale", under: target)
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

        private func makeStaleTestDirectory(
            named name: String,
            under root: URL
        ) throws -> URL {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: false
            )
            return url
        }
    }
#endif
