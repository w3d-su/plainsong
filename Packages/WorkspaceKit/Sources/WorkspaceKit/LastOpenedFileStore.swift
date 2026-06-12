import Foundation

public final class LastOpenedFileStore {
    public static let defaultKey = "BlogEditor.LastOpenedFileBookmark"

    private let userDefaults: UserDefaults
    private let key: String

    public init(userDefaults: UserDefaults = .standard, key: String = LastOpenedFileStore.defaultKey) {
        self.userDefaults = userDefaults
        self.key = key
    }

    public func save(_ url: URL) throws {
        let bookmarkData = try SecurityScopedAccess.withAccess(to: url) {
            try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }
        userDefaults.set(bookmarkData, forKey: key)
    }

    public func restore() throws -> URL? {
        guard let bookmarkData = userDefaults.data(forKey: key) else {
            return nil
        }

        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )

        if isStale {
            try save(url)
        }

        return url
    }

    public func clear() {
        userDefaults.removeObject(forKey: key)
    }
}
