import Foundation

/// One flat snapshot row. `sidecarIndex` is an opaque adapter slot.
///
/// Negative indexes belong to synthetic nodes such as the root. The pure tree
/// never interprets the slot as a filesystem identity.
public struct WorkspacePureEntry: Equatable, Sendable {
    public let relativePath: String
    public let kind: WorkspaceFileKind
    public let identity: String?
    public let contentModificationDate: Date?
    public let sidecarIndex: Int

    public init(
        relativePath: String,
        kind: WorkspaceFileKind,
        identity: String?,
        contentModificationDate: Date?,
        sidecarIndex: Int
    ) {
        self.relativePath = relativePath
        self.kind = kind
        self.identity = identity
        self.contentModificationDate = contentModificationDate
        self.sidecarIndex = sidecarIndex
    }

    public var preferredNodeID: String {
        WorkspaceDisplayNodeID.make(identity: identity, relativePath: relativePath)
    }
}

public struct WorkspacePureNode: Equatable, Sendable {
    public let id: String
    public let name: String
    public let relativePath: String
    public let kind: WorkspaceFileKind
    public let contentModificationDate: Date?
    public let sidecarIndex: Int
    public var children: [WorkspacePureNode]

    public init(
        id: String,
        name: String,
        relativePath: String,
        kind: WorkspaceFileKind,
        contentModificationDate: Date?,
        sidecarIndex: Int,
        children: [WorkspacePureNode] = []
    ) {
        self.id = id
        self.name = name
        self.relativePath = relativePath
        self.kind = kind
        self.contentModificationDate = contentModificationDate
        self.sidecarIndex = sidecarIndex
        self.children = children
    }
}

/// Filter, order, and expansion state for a flat snapshot. No filesystem I/O.
public struct WorkspacePureTree: Equatable, Sendable {
    public struct Options: Equatable, Sendable {
        public let showAllFiles: Bool

        public init(showAllFiles: Bool) {
            self.showAllFiles = showAllFiles
        }
    }

    public static let rootSidecarIndex = -1

    public private(set) var root: WorkspacePureNode
    public private(set) var expandedNodeIDs: Set<String>
    public private(set) var selectedNodeID: String?

    public init(
        root: WorkspacePureNode,
        expandedNodeIDs: Set<String> = [],
        selectedNodeID: String? = nil
    ) {
        self.root = root
        self.expandedNodeIDs = expandedNodeIDs
        self.selectedNodeID = selectedNodeID
    }

    public static func reconcile(
        previousExpandedNodeIDs: Set<String>,
        previousSelectedNodeID: String?,
        entries: [WorkspacePureEntry],
        options: Options
    ) -> WorkspacePureTree {
        let root = WorkspacePureTreeBuilder(entries: entries, options: options).build()
        if previousExpandedNodeIDs.isEmpty, previousSelectedNodeID == nil {
            return WorkspacePureTree(root: root)
        }
        let currentIDs = root.nodeIDs()
        let expanded = previousExpandedNodeIDs.intersection(currentIDs)
        let selected = previousSelectedNodeID.flatMap { currentIDs.contains($0) ? $0 : nil }
        return WorkspacePureTree(
            root: root,
            expandedNodeIDs: expanded,
            selectedNodeID: selected
        )
    }

    public mutating func setExpanded(_ isExpanded: Bool, for nodeID: String) {
        if isExpanded {
            expandedNodeIDs.insert(nodeID)
        } else {
            expandedNodeIDs.remove(nodeID)
        }
    }

    public func isExpanded(_ nodeID: String) -> Bool {
        expandedNodeIDs.contains(nodeID)
    }

    public mutating func selectNode(id nodeID: String?) {
        selectedNodeID = nodeID
    }

    public func node(id nodeID: String) -> WorkspacePureNode? {
        root.firstNode(id: nodeID)
    }
}

private struct WorkspacePureTreeBuilder {
    private struct Child {
        let entry: WorkspacePureEntry
        let parentPath: WorkspacePathByteKey
        let name: String
        let sortKey: WorkspacePathOrder.Key
        let sortPriority: Int
    }

    private struct PathParts {
        let parent: String
        let name: String

        init(_ path: String) {
            guard let separator = path.lastPathSeparatorIndex else {
                parent = ""
                name = path
                return
            }
            let prefix = path[..<separator]
            if path.hasTrailingPathSeparator {
                let components = path.splitOnPathSeparator()
                parent = components.dropLast().joined(separator: "/")
                name = components.last.map(String.init) ?? path
            } else {
                parent = prefix.containsPathSeparator
                    ? prefix.splitOnPathSeparator().joined(separator: "/")
                    : String(prefix)
                name = String(path[path.utf8.index(after: separator)...])
            }
        }
    }

    let entries: [WorkspacePureEntry]
    let options: WorkspacePureTree.Options

    func build() -> WorkspacePureNode {
        let visible = visibleEntries()
        var seenNodeIDs = Set<String>(minimumCapacity: visible.count)
        var duplicateNodeIDs: Set<String> = []
        for child in visible {
            let preferredID = child.entry.preferredNodeID
            if !seenNodeIDs.insert(preferredID).inserted {
                duplicateNodeIDs.insert(preferredID)
            }
        }
        let entriesByParent = Dictionary(grouping: visible, by: \.parentPath)
        let children = buildChildren(
            parentPath: WorkspacePathByteKey(""),
            entriesByParent: entriesByParent,
            duplicateNodeIDs: duplicateNodeIDs
        )
        return WorkspacePureNode(
            id: WorkspaceDisplayNodeID.root,
            name: "",
            relativePath: "",
            kind: .directory,
            contentModificationDate: nil,
            sidecarIndex: WorkspacePureTree.rootSidecarIndex,
            children: children
        )
    }

    private func visibleEntries() -> [Child] {
        var directoryPaths: Set<WorkspacePathByteKey> = []
        let candidates = entries.compactMap { entry -> Child? in
            guard options.showAllFiles || entry.kind.isVisibleByDefault else { return nil }
            let parts = PathParts(entry.relativePath)
            let parentPath = WorkspacePathByteKey(parts.parent)
            if !options.showAllFiles, entry.kind != .directory, !parts.parent.isEmpty,
               directoryPaths.insert(parentPath).inserted
            {
                var ancestor = parts.parent[...]
                while let separator = ancestor.lastPathSeparatorIndex {
                    ancestor = ancestor[..<separator]
                    let ancestorPath = WorkspacePathByteKey(String(ancestor))
                    guard directoryPaths.insert(ancestorPath).inserted else { break }
                }
            }
            return Child(
                entry: entry,
                parentPath: parentPath,
                name: parts.name,
                sortKey: WorkspacePathOrder.Key(entry.relativePath),
                sortPriority: options.showAllFiles ? 0 : defaultFilterSortPriority(entry.kind)
            )
        }
        guard !options.showAllFiles else { return candidates }
        return candidates.filter { child in
            child.entry.kind != .directory || directoryPaths.contains(WorkspacePathByteKey(child.entry.relativePath))
        }
    }

    private func buildChildren(
        parentPath: WorkspacePathByteKey,
        entriesByParent: [WorkspacePathByteKey: [Child]],
        duplicateNodeIDs: Set<String>
    ) -> [WorkspacePureNode] {
        (entriesByParent[parentPath] ?? [])
            .sorted { first, second in
                if first.sortPriority != second.sortPriority {
                    return first.sortPriority < second.sortPriority
                }
                return first.sortKey.isBefore(second.sortKey)
            }
            .map { child in
                let entry = child.entry
                let preferredID = entry.preferredNodeID
                let nodeID = duplicateNodeIDs.contains(preferredID)
                    ? WorkspaceDisplayNodeID.disambiguated(
                        preferredID,
                        relativePath: entry.relativePath
                    )
                    : preferredID
                return WorkspacePureNode(
                    id: nodeID,
                    name: child.name,
                    relativePath: entry.relativePath,
                    kind: entry.kind,
                    contentModificationDate: entry.contentModificationDate,
                    sidecarIndex: entry.sidecarIndex,
                    children: entry.kind == .directory
                        ? buildChildren(
                            parentPath: WorkspacePathByteKey(entry.relativePath),
                            entriesByParent: entriesByParent,
                            duplicateNodeIDs: duplicateNodeIDs
                        )
                        : []
                )
            }
    }

    private func defaultFilterSortPriority(_ kind: WorkspaceFileKind) -> Int {
        switch kind {
        case .markdown, .mdx:
            0
        case .image:
            1
        case .directory:
            2
        case .other:
            3
        }
    }
}

private extension WorkspacePureNode {
    func nodeIDs() -> Set<String> {
        var ids: Set<String> = []
        collectNodeIDs(into: &ids)
        return ids
    }

    func collectNodeIDs(into ids: inout Set<String>) {
        ids.insert(id)
        for child in children {
            child.collectNodeIDs(into: &ids)
        }
    }

    func firstNode(id nodeID: String) -> WorkspacePureNode? {
        if id == nodeID {
            return self
        }
        for child in children {
            if let found = child.firstNode(id: nodeID) {
                return found
            }
        }
        return nil
    }
}
