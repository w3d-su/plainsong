@testable import WorkspaceKit
import XCTest

final class RecentItemStoreTests: XCTestCase {
    func testRecentItemStorePersistsDeduplicatesAndCapsBookmarks() throws {
        let directory = try makeTemporaryDirectory()
        let first = directory.appendingPathComponent("first.md")
        let second = directory.appendingPathComponent("second.md")
        let third = directory.appendingPathComponent("third.md")
        try "1".write(to: first, atomically: true, encoding: .utf8)
        try "2".write(to: second, atomically: true, encoding: .utf8)
        try "3".write(to: third, atomically: true, encoding: .utf8)
        let suiteName = "Plainsong.RecentItemStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = RecentItemStore(userDefaults: defaults, key: "recents", maximumItems: 2)

        do {
            try store.save(first)
            try store.save(second)
            try store.save(first)
            try store.save(third)
        } catch {
            throw XCTSkip("Security-scoped bookmarks are unavailable in this test environment: \(error)")
        }

        let restored = try store.restore().map(\.standardizedFileURL)

        XCTAssertEqual(restored, [third, first].map(\.standardizedFileURL))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecentItemStoreTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
