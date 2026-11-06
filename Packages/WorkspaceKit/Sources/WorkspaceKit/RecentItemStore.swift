import Foundation

public final class RecentItemStore {
    public static let defaultKey = "Plainsong.RecentItemBookmarks"

    /// A resolved bookmark and whether the system asked for fresh bookmark data.
    struct Resolution {
        let url: URL
        let isStale: Bool
    }

    private let userDefaults: UserDefaults
    private let key: String
    private let maximumItems: Int
    private let resolveBookmark: (Data) throws -> Resolution
    private let makeBookmark: (URL) throws -> Data
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public convenience init(
        userDefaults: UserDefaults = .standard,
        key: String = RecentItemStore.defaultKey,
        maximumItems: Int = 10
    ) {
        self.init(
            userDefaults: userDefaults,
            key: key,
            maximumItems: maximumItems,
            resolveBookmark: RecentItemStore.resolveSecurityScopedBookmark,
            makeBookmark: RecentItemStore.makeSecurityScopedBookmark
        )
    }

    /// Test seam: bookmark creation and resolution are injected so unresolvable and stale
    /// entries can be produced deterministically.
    init(
        userDefaults: UserDefaults,
        key: String,
        maximumItems: Int,
        resolveBookmark: @escaping (Data) throws -> Resolution,
        makeBookmark: @escaping (URL) throws -> Data
    ) {
        self.userDefaults = userDefaults
        self.key = key
        self.maximumItems = maximumItems
        self.resolveBookmark = resolveBookmark
        self.makeBookmark = makeBookmark
    }

    public func save(_ url: URL) throws {
        let bookmarkData = try makeBookmark(url)
        var storedItems = loadStoredItems()
        storedItems.removeAll { storedItem in
            (try? resolveBookmark(storedItem.bookmarkData).url.standardizedFileURL) == url.standardizedFileURL
        }
        storedItems.insert(StoredRecentItem(bookmarkData: bookmarkData), at: 0)
        if storedItems.count > maximumItems {
            storedItems.removeLast(storedItems.count - maximumItems)
        }
        try persist(storedItems)
    }

    /// The recent items that resolve now, newest first.
    ///
    /// Each bookmark resolves on its own: one that cannot (a file on an unplugged drive)
    /// is skipped for this call but kept in storage, so it returns once its volume does.
    /// A stale bookmark is replaced with fresh data when that can be made.
    public func restore() throws -> [URL] {
        var storedItems = loadStoredItems()
        var urls: [URL] = []
        var refreshedAny = false
        for index in storedItems.indices {
            guard let resolution = try? resolveBookmark(storedItems[index].bookmarkData) else {
                continue
            }
            urls.append(resolution.url)
            if resolution.isStale, let fresh = try? makeBookmark(resolution.url) {
                storedItems[index] = StoredRecentItem(bookmarkData: fresh)
                refreshedAny = true
            }
        }
        if refreshedAny {
            try? persist(storedItems)
        }
        return urls
    }

    public func clear() {
        userDefaults.removeObject(forKey: key)
    }

    private func loadStoredItems() -> [StoredRecentItem] {
        guard let data = userDefaults.data(forKey: key),
              let items = try? decoder.decode([StoredRecentItem].self, from: data)
        else {
            return []
        }
        return items
    }

    private func persist(_ items: [StoredRecentItem]) throws {
        try userDefaults.set(encoder.encode(items), forKey: key)
    }

    private static func makeSecurityScopedBookmark(for url: URL) throws -> Data {
        try SecurityScopedAccess.withAccess(to: url) {
            try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }
    }

    private static func resolveSecurityScopedBookmark(_ bookmarkData: Data) throws -> Resolution {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return Resolution(url: url, isStale: isStale)
    }

    struct StoredRecentItem: Codable, Equatable {
        let bookmarkData: Data
    }
}
