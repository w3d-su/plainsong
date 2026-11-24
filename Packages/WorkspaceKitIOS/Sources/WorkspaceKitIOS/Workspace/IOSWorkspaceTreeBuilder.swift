import Foundation
import MarkdownCore
import WorkspaceCore

@MainActor
enum IOSWorkspaceTreeBuilder {
    static func makeSnapshot(
        record: IOSWorkspaceScopeRecord,
        items: [IOSWorkspaceFileItem],
        requestID: UUID,
        includesHiddenEntries: Bool,
        includesAllFiles: Bool
    ) -> IOSWorkspaceSnapshot {
        let visible = items.filter {
            shouldInclude(
                $0,
                includesHiddenEntries: includesHiddenEntries,
                includesAllFiles: includesAllFiles
            )
        }
        let entries = nest(
            childrenByParent(visible),
            parent: "",
            record: record,
            previousIDs: previousIDs(record.latestSnapshot)
        )
        return IOSWorkspaceSnapshot(
            workspaceID: record.workspaceID,
            accessGeneration: record.generation,
            requestID: requestID,
            entries: entries
        )
    }

    static func singleFileEntry(
        record: IOSWorkspaceScopeRecord,
        item: IOSWorkspaceFileItem
    ) -> IOSWorkspaceEntry? {
        let relative = item.relativePath.isEmpty ? record.displayName : item.relativePath
        guard let location = location(record: record, relativePath: relative, item: item) else { return nil }
        return IOSWorkspaceEntry(
            id: previousIDs(record.latestSnapshot)[WorkspacePathByteKey(relative)] ?? UUID(),
            location: location,
            kind: kind(for: item),
            availability: item.availability,
            children: []
        )
    }

    /// Entry IDs of the last published tree by byte-exact path. A refresh keeps the ID of every
    /// path that is still there, so selection, expansion and the search read cache survive it.
    private static func previousIDs(_ snapshot: IOSWorkspaceSnapshot?) -> [WorkspacePathByteKey: UUID] {
        var ids: [WorkspacePathByteKey: UUID] = [:]
        var pending = snapshot?.entries ?? []
        while let entry = pending.popLast() {
            ids[WorkspacePathByteKey(entry.location.relativePath)] = entry.id
            pending.append(contentsOf: entry.children)
        }
        return ids
    }

    private static func shouldInclude(
        _ item: IOSWorkspaceFileItem,
        includesHiddenEntries: Bool,
        includesAllFiles: Bool
    ) -> Bool {
        if item.isSymlink {
            return false
        }
        if !includesHiddenEntries, IOSWorkspacePathAuthority.isHiddenSpelling(item.relativePath) {
            return false
        }
        let entryKind = kind(for: item)
        if includesAllFiles {
            return true
        }
        switch entryKind {
        case .directory, .document, .image:
            return true
        case .other:
            return false
        }
    }

    /// Groups the items by parent once, so building the tree is linear in the item count.
    private static func childrenByParent(
        _ items: [IOSWorkspaceFileItem]
    ) -> [WorkspacePathByteKey: [IOSWorkspaceFileItem]] {
        var children: [WorkspacePathByteKey: [IOSWorkspaceFileItem]] = [:]
        for item in items {
            let parent = WorkspacePathByteKey(IOSWorkspacePathAuthority.parentSpelling(item.relativePath))
            children[parent, default: []].append(item)
        }
        return children
    }

    private static func nest(
        _ childrenByParent: [WorkspacePathByteKey: [IOSWorkspaceFileItem]],
        parent: String,
        record: IOSWorkspaceScopeRecord,
        previousIDs: [WorkspacePathByteKey: UUID]
    ) -> [IOSWorkspaceEntry] {
        // Providers list in no fixed order; the tree must not reorder between refreshes.
        let children = (childrenByParent[WorkspacePathByteKey(parent)] ?? []).sorted {
            WorkspacePathOrder.isBefore($0.relativePath, $1.relativePath)
        }
        return children.compactMap { item in
            guard let location = location(record: record, relativePath: item.relativePath, item: item) else {
                return nil
            }
            let nested = item.isDirectory
                ? nest(childrenByParent, parent: item.relativePath, record: record, previousIDs: previousIDs)
                : []
            return IOSWorkspaceEntry(
                id: previousIDs[WorkspacePathByteKey(item.relativePath)] ?? UUID(),
                location: location,
                kind: kind(for: item),
                availability: item.availability,
                children: nested
            )
        }
    }

    private static func location(
        record: IOSWorkspaceScopeRecord,
        relativePath: String,
        item: IOSWorkspaceFileItem
    ) -> IOSFileLocation? {
        guard WorkspaceRelativePath(spelling: relativePath) != nil else { return nil }
        return IOSFileLocation(
            workspaceID: record.workspaceID,
            accessGeneration: record.generation,
            relativePath: relativePath,
            fileURL: item.url,
            resourceID: item.providerIdentity.map { IOSWorkspaceResourceIdentity(rawValue: $0) }
        )
    }

    private static func kind(for item: IOSWorkspaceFileItem) -> IOSWorkspaceEntry.Kind {
        if item.isDirectory {
            return .directory
        }
        let fileKind = WorkspaceFileKind(url: item.url, isDirectory: false)
        switch fileKind {
        case .directory:
            return .directory
        case .markdown, .mdx:
            return .document(FileKind(url: item.url) ?? .markdown)
        case .image:
            return .image
        case .other:
            return .other
        }
    }
}
