import Foundation

public struct WorkspaceSessionEviction: Sendable, Equatable {
    public let url: URL
    public let requiresSave: Bool

    public init(url: URL, requiresSave: Bool) {
        self.url = url
        self.requiresSave = requiresSave
    }
}

public enum WorkspaceSessionRelocationError: Error, Sendable, Equatable {
    case sourceMissing(URL)
    case destinationOccupied(URL)
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
    public mutating func access(
        _ url: URL,
        isDirty: Bool,
        protectedURLs: Set<URL> = []
    ) -> [WorkspaceSessionEviction] {
        // Session maps use the retained lexical URL spelling. `standardizedFileURL` silently
        // rewrites NFC to NFD on macOS, collapsing distinct exact locations and returning an
        // eviction key that cannot address the App's retained-session cache.
        let key = url
        entries[key] = Entry(isDirty: isDirty)
        refreshRecency(for: key)
        return enforceLimit(protectedURLs: protectedURLs)
    }

    public mutating func updateDirtyState(for url: URL, isDirty: Bool) {
        let key = url
        guard entries[key] != nil else { return }
        entries[key] = Entry(isDirty: isDirty)
    }

    public func dirtyState(for url: URL) -> Bool? {
        entries[url]?.isDirty
    }

    public mutating func remove(_ url: URL) {
        let key = url
        entries[key] = nil
        leastRecentURLs.removeAll { $0 == key }
    }

    /// Rekeys an existing warm-session entry without changing dirty state or recency.
    ///
    /// Destination ownership is exclusive. Failing before either collection is changed keeps
    /// the policy suitable for the App's larger all-or-nothing session relocation transaction.
    public mutating func relocate(from sourceURL: URL, to destinationURL: URL) throws {
        guard sourceURL != destinationURL else { return }
        guard let entry = entries[sourceURL] else {
            throw WorkspaceSessionRelocationError.sourceMissing(sourceURL)
        }
        guard entries[destinationURL] == nil else {
            throw WorkspaceSessionRelocationError.destinationOccupied(destinationURL)
        }
        guard let recencyIndex = leastRecentURLs.firstIndex(of: sourceURL) else {
            preconditionFailure("Workspace session LRU entry has no recency record")
        }

        entries[sourceURL] = nil
        entries[destinationURL] = entry
        leastRecentURLs[recencyIndex] = destinationURL
    }

    public mutating func trim(protectedURLs: Set<URL> = []) -> [WorkspaceSessionEviction] {
        enforceLimit(protectedURLs: protectedURLs)
    }

    private mutating func refreshRecency(for url: URL) {
        leastRecentURLs.removeAll { $0 == url }
        leastRecentURLs.append(url)
    }

    private mutating func enforceLimit(protectedURLs: Set<URL>) -> [WorkspaceSessionEviction] {
        var evictions: [WorkspaceSessionEviction] = []

        while leastRecentURLs.count > limit {
            guard let evictionIndex = leastRecentURLs.firstIndex(where: {
                !protectedURLs.contains($0)
            }) else {
                break
            }
            let evicted = leastRecentURLs.remove(at: evictionIndex)
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
