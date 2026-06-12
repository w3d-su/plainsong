import Foundation

public struct WorkspaceSessionEviction: Sendable, Equatable {
    public let url: URL
    public let requiresSave: Bool

    public init(url: URL, requiresSave: Bool) {
        self.url = url
        self.requiresSave = requiresSave
    }
}

public struct WorkspaceSessionLRUPolicy: Sendable, Equatable {
    public let limit: Int

    private var entries: [URL: Entry] = [:]
    private var leastRecentURLs: [URL] = []

    public var warmURLsInLeastRecentOrder: [URL] {
        leastRecentURLs
    }

    public init(limit: Int = 8) {
        precondition(limit > 0, "Workspace session cache limit must be positive.")
        self.limit = limit
    }

    @discardableResult
    public mutating func access(_ url: URL, isDirty: Bool) -> [WorkspaceSessionEviction] {
        let key = url.standardizedFileURL
        entries[key] = Entry(isDirty: isDirty)
        refreshRecency(for: key)
        return enforceLimit()
    }

    public mutating func updateDirtyState(for url: URL, isDirty: Bool) {
        let key = url.standardizedFileURL
        guard entries[key] != nil else { return }
        entries[key] = Entry(isDirty: isDirty)
    }

    public mutating func remove(_ url: URL) {
        let key = url.standardizedFileURL
        entries[key] = nil
        leastRecentURLs.removeAll { $0 == key }
    }

    private mutating func refreshRecency(for url: URL) {
        leastRecentURLs.removeAll { $0 == url }
        leastRecentURLs.append(url)
    }

    private mutating func enforceLimit() -> [WorkspaceSessionEviction] {
        var evictions: [WorkspaceSessionEviction] = []

        while leastRecentURLs.count > limit, let evicted = leastRecentURLs.first {
            leastRecentURLs.removeFirst()
            let entry = entries.removeValue(forKey: evicted)
            evictions.append(
                WorkspaceSessionEviction(
                    url: evicted,
                    requiresSave: entry?.isDirty == true
                )
            )
        }

        return evictions
    }

    private struct Entry: Equatable {
        let isDirty: Bool
    }
}
