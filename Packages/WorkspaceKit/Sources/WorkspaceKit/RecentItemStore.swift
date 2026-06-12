import Foundation

public final class RecentItemStore {
    public static let defaultKey = "Plainsong.RecentItemBookmarks"

    private let userDefaults: UserDefaults
    private let key: String
    private let maximumItems: Int
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        userDefaults: UserDefaults = .standard,
        key: String = RecentItemStore.defaultKey,
        maximumItems: Int = 10
    ) {
        self.userDefaults = userDefaults
        self.key = key
        self.maximumItems = maximumItems
    }

    public func save(_ url: URL) throws {
        let bookmarkData = try SecurityScopedAccess.withAccess(to: url) {
            try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }
        var storedItems = loadStoredItems()
        storedItems.removeAll { storedItem in
            (try? resolve(storedItem).standardizedFileURL) == url.standardizedFileURL
        }
        storedItems.insert(StoredRecentItem(bookmarkData: bookmarkData), at: 0)
        if storedItems.count > maximumItems {
            storedItems.removeLast(storedItems.count - maximumItems)
        }
        try persist(storedItems)
    }

    public func restore() throws -> [URL] {
        try loadStoredItems().map(resolve(_:))
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

    private func resolve(_ item: StoredRecentItem) throws -> URL {
        var isStale = false
        return try URL(
            resolvingBookmarkData: item.bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    private struct StoredRecentItem: Codable {
        let bookmarkData: Data
    }
}
