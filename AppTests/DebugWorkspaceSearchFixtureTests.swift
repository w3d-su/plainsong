#if DEBUG
    @testable import Plainsong
    import XCTest

    final class DebugWorkspaceSearchFixtureTests: XCTestCase {
        func testRemoveStaleFixturesOnlyDeletesExpiredWS4ADirectories() throws {
            let fileManager = FileManager.default
            let root = fileManager.temporaryDirectory
                .appendingPathComponent("FixtureCleanup-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: root) }

            let current = try makeDirectory(named: "ws4a-current", under: root)
            let stale = try makeDirectory(named: "ws4a-stale", under: root)
            let recent = try makeDirectory(named: "ws4a-recent", under: root)
            let unrelated = try makeDirectory(named: "other-stale", under: root)
            let symlink = root.appendingPathComponent("ws4a-link")
            try fileManager.createSymbolicLink(at: symlink, withDestinationURL: unrelated)

            let now = Date(timeIntervalSinceReferenceDate: 10000)
            let expired = now.addingTimeInterval(
                -DebugWorkspaceSearchFixture.staleFixtureAge - 1
            )
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

            try DebugWorkspaceSearchFixture.removeStaleFixtures(
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

        private func makeDirectory(named name: String, under root: URL) throws -> URL {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            return url
        }
    }
#endif
