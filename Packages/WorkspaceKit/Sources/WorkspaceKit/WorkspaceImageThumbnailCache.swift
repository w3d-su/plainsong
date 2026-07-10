import Foundation

/// Bounded LRU cache keyed by resolved path + mtime + target pixel size.
struct WorkspaceImageThumbnailCache {
    struct Key: Hashable {
        let resolvedWorkspaceRelativePath: String
        let contentModificationTime: TimeInterval
        let maxPixelSize: Int
    }

    private struct Entry {
        let thumbnail: WorkspaceImageThumbnail
        let cost: Int
    }

    private let byteBudget: Int
    private var entries: [Key: Entry] = [:]
    private var order: [Key] = []
    private(set) var stats = WorkspaceImageThumbnailCacheStats()

    init(byteBudget: Int) {
        precondition(byteBudget > 0, "Thumbnail cache budget must be positive.")
        self.byteBudget = byteBudget
    }

    /// Returns a cached thumbnail and records a hit. Does not record misses.
    mutating func lookup(_ key: Key) -> WorkspaceImageThumbnail? {
        guard let entry = entries[key] else {
            return nil
        }
        refresh(key)
        stats.hits += 1
        return entry.thumbnail
    }

    mutating func recordMiss() {
        stats.misses += 1
    }

    mutating func insert(_ thumbnail: WorkspaceImageThumbnail, for key: Key) {
        if let existing = entries[key] {
            stats.totalByteCost -= existing.cost
            entries[key] = nil
            order.removeAll { $0 == key }
        }

        let entry = Entry(thumbnail: thumbnail, cost: max(thumbnail.decodedByteCost, 1))
        entries[key] = entry
        order.append(key)
        stats.totalByteCost += entry.cost
        stats.entryCount = entries.count
        enforceBudget()
    }

    mutating func recordCoalescedLoad() {
        stats.coalescedLoads += 1
    }

    var snapshotStats: WorkspaceImageThumbnailCacheStats {
        var copy = stats
        copy.entryCount = entries.count
        return copy
    }

    private mutating func refresh(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private mutating func enforceBudget() {
        while stats.totalByteCost > byteBudget, let oldest = order.first {
            order.removeFirst()
            if let removed = entries.removeValue(forKey: oldest) {
                stats.totalByteCost -= removed.cost
                stats.evictions += 1
            }
        }
        stats.entryCount = entries.count
        if stats.totalByteCost < 0 {
            stats.totalByteCost = 0
        }
    }
}
