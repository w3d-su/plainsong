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

    func testOneUnresolvableBookmarkHidesOnlyItselfAndStaysStored() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let unplugged = URL(fileURLWithPath: "/Volumes/Unplugged/post.md")
        let store = makeFakeStore(defaults: defaults, unresolvable: [unplugged])

        try store.save(URL(fileURLWithPath: "/tmp/a.md"))
        try store.save(unplugged)
        try store.save(URL(fileURLWithPath: "/tmp/b.md"))

        XCTAssertEqual(try store.restore().map(\.path), ["/tmp/b.md", "/tmp/a.md"])
        XCTAssertEqual(try storedPaths(in: defaults), ["/tmp/b.md", unplugged.path, "/tmp/a.md"])

        // The drive comes back: the entry reappears in its place.
        let remounted = makeFakeStore(defaults: defaults, unresolvable: [])
        XCTAssertEqual(try remounted.restore().map(\.path), ["/tmp/b.md", unplugged.path, "/tmp/a.md"])
    }

    func testStaleBookmarkIsRefreshedInPlace() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let moved = URL(fileURLWithPath: "/tmp/moved.md")
        try makeFakeStore(defaults: defaults, unresolvable: []).save(URL(fileURLWithPath: "/tmp/a.md"))
        try makeFakeStore(defaults: defaults, unresolvable: []).save(moved)
        let staleData = try XCTUnwrap(storedBookmarks(in: defaults).first)

        var madeBookmarks: [URL] = []
        let store = RecentItemStore(
            userDefaults: defaults,
            key: "recents",
            maximumItems: 10,
            resolveBookmark: { data in
                let url = Self.fakeURL(from: data)
                return .init(url: url, isStale: data == staleData)
            },
            makeBookmark: { url in
                madeBookmarks.append(url)
                return Self.fakeBookmark(for: url, generation: 2)
            }
        )

        XCTAssertEqual(try store.restore().map(\.path), [moved.path, "/tmp/a.md"])
        XCTAssertEqual(madeBookmarks, [moved])
        let stored = try storedBookmarks(in: defaults)
        XCTAssertEqual(stored.first, Self.fakeBookmark(for: moved, generation: 2))
        XCTAssertEqual(stored.count, 2)
    }

    private func makeFakeStore(defaults: UserDefaults, unresolvable: Set<URL>) -> RecentItemStore {
        RecentItemStore(
            userDefaults: defaults,
            key: "recents",
            maximumItems: 10,
            resolveBookmark: { data in
                let url = Self.fakeURL(from: data)
                if unresolvable.contains(url) { throw CocoaError(.fileNoSuchFile) }
                return .init(url: url, isStale: false)
            },
            makeBookmark: { Self.fakeBookmark(for: $0, generation: 1) }
        )
    }

    private static func fakeBookmark(for url: URL, generation: Int) -> Data {
        Data("\(generation)|\(url.path)".utf8)
    }

    private static func fakeURL(from data: Data) -> URL {
        let text = String(bytes: data, encoding: .utf8) ?? ""
        return URL(fileURLWithPath: String(text.split(separator: "|", maxSplits: 1)[1]))
    }

    private func storedBookmarks(in defaults: UserDefaults) throws -> [Data] {
        let data = try XCTUnwrap(defaults.data(forKey: "recents"))
        return try JSONDecoder().decode([RecentItemStore.StoredRecentItem].self, from: data).map(\.bookmarkData)
    }

    private func storedPaths(in defaults: UserDefaults) throws -> [String] {
        try storedBookmarks(in: defaults).map { Self.fakeURL(from: $0).path }
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "Plainsong.RecentItemStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecentItemStoreTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
