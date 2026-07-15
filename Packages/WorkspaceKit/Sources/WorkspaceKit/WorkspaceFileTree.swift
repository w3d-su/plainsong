import Foundation
import MarkdownCore

public enum WorkspaceFileKind: Sendable, Equatable {
    case directory
    case markdown
    case mdx
    case image
    case other

    public init(url: URL, isDirectory: Bool) {
        if isDirectory {
            self = .directory
        } else if let fileKind = FileKind(url: url) {
            switch fileKind {
            case .markdown:
                self = .markdown
            case .mdx:
                self = .mdx
            }
        } else if Self.imageExtensions.contains(url.pathExtension.lowercased()) {
            self = .image
        } else {
            self = .other
        }
    }

    public var isEditableMarkdown: Bool {
        switch self {
        case .markdown, .mdx:
            true
        case .directory, .image, .other:
            false
        }
    }

    public var isVisibleByDefault: Bool {
        switch self {
        case .directory, .markdown, .mdx, .image:
            true
        case .other:
            false
        }
    }

    private static let imageExtensions: Set<String> = [
        "apng",
        "avif",
        "gif",
        "heic",
        "heif",
        "jpeg",
        "jpg",
        "png",
        "svg",
        "tif",
        "tiff",
        "webp",
    ]
}

public struct WorkspaceFileSnapshot: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let relativePath: String
        public let kind: WorkspaceFileKind
        public let identity: String?
        public let contentModificationDate: Date?

        public init(
            relativePath: String,
            kind: WorkspaceFileKind,
            identity: String?,
            contentModificationDate: Date?
        ) {
            self.relativePath = Self.normalized(relativePath)
            self.kind = kind
            self.identity = identity
            self.contentModificationDate = contentModificationDate
        }

        public var nodeID: WorkspaceFileNode.ID {
            guard let identity else {
                return workspaceFileTreeFallbackPathIDPrefix
                    + WorkspacePathByteKey(relativePath).asciiHex
            }
            return identity
        }

        private static func normalized(_ path: String) -> String {
            let components = path
                .split(separator: "/", omittingEmptySubsequences: true)
                .joined(separator: "/")
            // Preserve an absolute-path marker until the consumer performs containment
            // validation. Dropping it here would turn a hostile snapshot entry into a
            // seemingly safe workspace-relative path.
            return path.hasPrefix("/") ? "/\(components)" : components
        }
    }

    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }
}

public struct WorkspaceFileNode: Identifiable, Sendable, Equatable {
    // swiftlint:disable:next type_name
    public typealias ID = String

    public let id: ID
    public let name: String
    public let relativePath: String
    public let kind: WorkspaceFileKind
    public let contentModificationDate: Date?
    public var children: [WorkspaceFileNode]

    public var isDirectory: Bool {
        kind == .directory
    }

    public var isEditableMarkdown: Bool {
        kind.isEditableMarkdown
    }

    public init(
        id: ID,
        name: String,
        relativePath: String,
        kind: WorkspaceFileKind,
        contentModificationDate: Date?,
        children: [WorkspaceFileNode] = []
    ) {
        self.id = id
        self.name = name
        self.relativePath = relativePath
        self.kind = kind
        self.contentModificationDate = contentModificationDate
        self.children = children
    }
}

public struct WorkspaceFileTree: Sendable, Equatable {
    public struct Options: Sendable, Equatable {
        public let showAllFiles: Bool

        public init(showAllFiles: Bool) {
            self.showAllFiles = showAllFiles
        }
    }

    public private(set) var root: WorkspaceFileNode
    public private(set) var expandedNodeIDs: Set<WorkspaceFileNode.ID>
    public private(set) var selectedNodeID: WorkspaceFileNode.ID?

    public var selectedNode: WorkspaceFileNode? {
        guard let selectedNodeID else { return nil }
        return node(id: selectedNodeID)
    }

    public init(
        root: WorkspaceFileNode,
        expandedNodeIDs: Set<WorkspaceFileNode.ID> = [],
        selectedNodeID: WorkspaceFileNode.ID? = nil
    ) {
        self.root = root
        self.expandedNodeIDs = expandedNodeIDs
        self.selectedNodeID = selectedNodeID
    }

    public static func reconcile(
        previous: WorkspaceFileTree?,
        snapshot: WorkspaceFileSnapshot,
        options: Options
    ) -> WorkspaceFileTree {
        let root = WorkspaceFileTreeBuilder(snapshot: snapshot, options: options).build()
        let currentIDs = root.nodeIDs()
        let expanded = previous?.expandedNodeIDs.intersection(currentIDs) ?? []
        let selected = previous?.selectedNodeID.flatMap { currentIDs.contains($0) ? $0 : nil }

        return WorkspaceFileTree(
            root: root,
            expandedNodeIDs: expanded,
            selectedNodeID: selected
        )
    }

    public mutating func setExpanded(_ isExpanded: Bool, for nodeID: WorkspaceFileNode.ID) {
        if isExpanded {
            expandedNodeIDs.insert(nodeID)
        } else {
            expandedNodeIDs.remove(nodeID)
        }
    }

    public func isExpanded(_ nodeID: WorkspaceFileNode.ID) -> Bool {
        expandedNodeIDs.contains(nodeID)
    }

    public mutating func selectNode(id nodeID: WorkspaceFileNode.ID?) {
        selectedNodeID = nodeID
    }

    public func node(id nodeID: WorkspaceFileNode.ID) -> WorkspaceFileNode? {
        root.firstNode(id: nodeID)
    }
}

private struct WorkspaceFileTreeBuilder {
    let snapshot: WorkspaceFileSnapshot
    let options: WorkspaceFileTree.Options

    func build() -> WorkspaceFileNode {
        let entriesByParent = Dictionary(
            grouping: visibleEntries(),
            by: { WorkspacePathByteKey(parentPath(of: $0)) }
        )
        let children = buildChildren(
            parentPath: WorkspacePathByteKey(""),
            entriesByParent: entriesByParent
        )
        return WorkspaceFileNode(
            id: workspaceFileTreeRootID,
            name: "",
            relativePath: "",
            kind: .directory,
            contentModificationDate: nil,
            children: children
        )
    }

    private func visibleEntries() -> [WorkspaceFileSnapshot.Entry] {
        guard !options.showAllFiles else {
            return snapshot.entries
        }

        var directoryPaths: Set<WorkspacePathByteKey> = []
        let directlyVisible = snapshot.entries.filter { entry in
            guard entry.kind != .directory, entry.kind.isVisibleByDefault else { return false }
            insertAncestorPaths(of: entry.relativePath, into: &directoryPaths)
            return true
        }
        let directlyVisiblePaths = Set(directlyVisible.map { WorkspacePathByteKey($0.relativePath) })

        return snapshot.entries.filter { entry in
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
        entriesByParent: [WorkspacePathByteKey: [WorkspaceFileSnapshot.Entry]]
    ) -> [WorkspaceFileNode] {
        (entriesByParent[parentPath] ?? [])
            .sorted { first, second in
                compare(first, second)
            }
            .map { entry in
                WorkspaceFileNode(
                    id: entry.nodeID,
                    name: lastPathComponent(of: entry.relativePath),
                    relativePath: entry.relativePath,
                    kind: entry.kind,
                    contentModificationDate: entry.contentModificationDate,
                    children: entry.kind == .directory
                        ? buildChildren(
                            parentPath: WorkspacePathByteKey(entry.relativePath),
                            entriesByParent: entriesByParent
                        )
                        : []
                )
            }
    }

    private func compare(_ first: WorkspaceFileSnapshot.Entry, _ second: WorkspaceFileSnapshot.Entry) -> Bool {
        if !options.showAllFiles {
            let firstPriority = defaultFilterSortPriority(first.kind)
            let secondPriority = defaultFilterSortPriority(second.kind)
            if firstPriority != secondPriority {
                return firstPriority < secondPriority
            }
        }

        let pathComparison = first.relativePath.compare(
            second.relativePath,
            options: [.caseInsensitive, .numeric]
        )
        if pathComparison != .orderedSame {
            return pathComparison == .orderedAscending
        }
        return WorkspacePathByteKey(first.relativePath) < WorkspacePathByteKey(second.relativePath)
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

    private func parentPath(of entry: WorkspaceFileSnapshot.Entry) -> String {
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
        relativePath.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? relativePath
    }
}

private let workspaceFileTreeRootID = "__workspace_root__"
private let workspaceFileTreeFallbackPathIDPrefix = "__workspace_path_bytes__:"

private extension WorkspaceFileNode {
    func nodeIDs() -> Set<WorkspaceFileNode.ID> {
        var ids: Set<WorkspaceFileNode.ID> = []
        collectNodeIDs(into: &ids)
        return ids
    }

    func collectNodeIDs(into ids: inout Set<WorkspaceFileNode.ID>) {
        ids.insert(id)
        for child in children {
            child.collectNodeIDs(into: &ids)
        }
    }

    func firstNode(id nodeID: WorkspaceFileNode.ID) -> WorkspaceFileNode? {
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
