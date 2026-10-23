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
    let entries: [WorkspacePureEntry]
    let options: WorkspacePureTree.Options

    func build() -> WorkspacePureNode {
        let visible = visibleEntries()
        let duplicateNodeIDs = Set(
            Dictionary(grouping: visible, by: \.preferredNodeID)
                .compactMap { nodeID, matches in matches.count > 1 ? nodeID : nil }
        )
        let entriesByParent = Dictionary(
            grouping: visible,
            by: { WorkspacePathByteKey(parentPath(of: $0)) }
        )
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

    private func visibleEntries() -> [WorkspacePureEntry] {
        guard !options.showAllFiles else {
            return entries
        }

        var directoryPaths: Set<WorkspacePathByteKey> = []
        let directlyVisible = entries.filter { entry in
            guard entry.kind != .directory, entry.kind.isVisibleByDefault else { return false }
            insertAncestorPaths(of: entry.relativePath, into: &directoryPaths)
            return true
        }
        let directlyVisiblePaths = Set(directlyVisible.map { WorkspacePathByteKey($0.relativePath) })

        return entries.filter { entry in
            let pathKey = WorkspacePathByteKey(entry.relativePath)
            return switch entry.kind {
            case .directory:
                directoryPaths.contains(pathKey)
            case .markdown, .mdx, .image:
                directlyVisiblePaths.contains(pathKey)
            case .other:
                false
            }
        }
    }

    private func buildChildren(
        parentPath: WorkspacePathByteKey,
        entriesByParent: [WorkspacePathByteKey: [WorkspacePureEntry]],
        duplicateNodeIDs: Set<String>
    ) -> [WorkspacePureNode] {
        (entriesByParent[parentPath] ?? [])
            .sorted { first, second in
                compare(first, second)
            }
            .map { entry in
                let preferredID = entry.preferredNodeID
                let nodeID = duplicateNodeIDs.contains(preferredID)
                    ? WorkspaceDisplayNodeID.disambiguated(
                        preferredID,
                        relativePath: entry.relativePath
                    )
                    : preferredID
                return WorkspacePureNode(
                    id: nodeID,
                    name: lastPathComponent(of: entry.relativePath),
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

    private func compare(_ first: WorkspacePureEntry, _ second: WorkspacePureEntry) -> Bool {
        if !options.showAllFiles {
            let firstPriority = defaultFilterSortPriority(first.kind)
            let secondPriority = defaultFilterSortPriority(second.kind)
            if firstPriority != secondPriority {
                return firstPriority < secondPriority
            }
        }
        return WorkspacePathOrder.isBefore(first.relativePath, second.relativePath)
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

    private func parentPath(of entry: WorkspacePureEntry) -> String {
        let components = entry.relativePath.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count > 1 else { return "" }
        return components.dropLast().joined(separator: "/")
    }

    private func insertAncestorPaths(
        of relativePath: String,
        into paths: inout Set<WorkspacePathByteKey>
    ) {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count > 1 else { return }

        var current = ""
        for component in components.dropLast() {
            if current.isEmpty {
                current = String(component)
            } else {
                current += "/\(component)"
            }
            paths.insert(WorkspacePathByteKey(current))
        }
    }

    private func lastPathComponent(of relativePath: String) -> String {
        relativePath.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init)
            ?? relativePath
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
