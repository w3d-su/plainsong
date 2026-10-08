import Foundation

final class AccessGrant: @unchecked Sendable {
    enum Scope: String, Codable { case singleFile, directory }
    let root: URL
    let scope: Scope
    private let started: Bool
    private let lock = NSLock()
    private var released = false

    init(root: URL, scope: Scope, appPrivate: Bool = false) throws {
        self.root = root
        self.scope = scope
        started = appPrivate ? false : root.startAccessingSecurityScopedResource()
        guard started || appPrivate else { throw CocoaError(.fileReadNoPermission) }
    }

    deinit { release() }

    func release() {
        lock.lock()
        defer { lock.unlock() }
        guard !released else { return }
        released = true
        if started {
            root.stopAccessingSecurityScopedResource()
        }
    }

    func saveRecent() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !released else { throw CocoaError(.fileReadNoPermission) }
        let data = try root.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        // Opaque bookmarks remain app-private. Never export or log them.
        UserDefaults.standard.set(data, forKey: "M0RecentBookmark")
        UserDefaults.standard.set(scope.rawValue, forKey: "M0RecentScope")
    }

    static func restoreRecent() throws -> AccessGrant {
        guard let data = UserDefaults.standard.data(forKey: "M0RecentBookmark"),
              let raw = UserDefaults.standard.string(forKey: "M0RecentScope"), let scope = Scope(rawValue: raw)
        else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale else { throw CocoaError(.fileReadNoPermission) }
        return try AccessGrant(root: url, scope: scope)
    }

    func listMarkdownFiles() throws -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        guard !released else { throw CocoaError(.fileReadNoPermission) }
        guard scope == .directory else { throw CocoaError(.fileReadNoPermission) }
        var coordinationError: NSError?
        var result: Result<[URL], Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: root, options: [], error: &coordinationError) { coordinated in
            result = Result {
                try FileManager.default.contentsOfDirectory(at: coordinated,
                                                            includingPropertiesForKeys: [
                                                                .isRegularFileKey,
                                                                .isSymbolicLinkKey,
                                                            ], options: [.skipsHiddenFiles])
                    .filter {
                        let values = try $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                        return values.isRegularFile == true && values.isSymbolicLink != true &&
                            ["md", "markdown", "mdx"].contains($0.pathExtension.lowercased())
                    }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
            }
        }
        if let coordinationError {
            throw coordinationError
        }
        return try result.get()
    }
}
