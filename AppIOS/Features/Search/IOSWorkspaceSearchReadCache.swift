import Foundation
import WorkspaceCore

/// Bounded text of files read by earlier searches, keyed by grant generation and path.
/// Only successful reads and size or encoding refusals are kept; anything else retries.
struct IOSWorkspaceSearchReadCache {
    static let maximumBytes = 32 * 1024 * 1024

    /// Compared by exact UTF-8 bytes. A joined `String` key equated canonically equivalent
    /// paths (NFC and NFD spellings are different files) and let a path containing the
    /// separator match another file's key.
    struct Key: Hashable {
        let workspace: UUID
        let generation: UInt64
        let path: [UInt8]
    }

    private var entries: [Key: IOSWorkspaceSearchController.Load] = [:]
    private var bytes = 0
    /// Bumped when any entry is dropped, so a read already in flight cannot cache
    /// the text it fetched before that drop.
    private var revision: UInt64 = 0

    var count: Int {
        entries.count
    }

    var epoch: UInt64 {
        revision
    }

    mutating func removeAll() {
        entries.removeAll()
        bytes = 0
        revision &+= 1
    }

    func load(_ location: IOSFileLocation) -> IOSWorkspaceSearchController.Load? {
        entries[Self.key(location.workspaceID, location.accessGeneration, location.relativePath)]
    }

    mutating func store(_ load: IOSWorkspaceSearchController.Load, for location: IOSFileLocation) {
        let size = if case let .text(text) = load {
            text.utf8.count
        } else {
            0
        }
        guard bytes + size <= Self.maximumBytes else { return }
        let key = Self.key(location.workspaceID, location.accessGeneration, location.relativePath)
        if let previous = entries[key], case let .text(text) = previous {
            bytes -= text.utf8.count
        }
        entries[key] = load
        bytes += size
    }

    /// The open document is searched from its live buffer; its disk text is dropped so a
    /// later search after switching documents reads the saved file again.
    mutating func remove(_ open: IOSWorkspaceSearchOpenDocument) {
        let workspace = open.workspaceID.rawValue
        let path = Array(open.relativePath.utf8)
        var removed = false
        for key in entries.keys where key.workspace == workspace && key.path == path {
            if case let .text(text) = entries.removeValue(forKey: key) {
                bytes -= text.utf8.count
            }
            removed = true
        }
        if removed {
            revision &+= 1
        }
    }

    mutating func remove(_ location: IOSFileLocation) {
        let key = Self.key(location.workspaceID, location.accessGeneration, location.relativePath)
        guard let previous = entries.removeValue(forKey: key) else {
            revision &+= 1
            return
        }
        if case let .text(text) = previous {
            bytes -= text.utf8.count
        }
        revision &+= 1
    }

    private static func key(_ workspace: IOSWorkspaceIdentity, _ generation: UInt64, _ path: String) -> Key {
        Key(workspace: workspace.rawValue, generation: generation, path: Array(path.utf8))
    }
}
