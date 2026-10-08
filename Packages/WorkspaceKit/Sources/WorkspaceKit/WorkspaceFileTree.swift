import Foundation
import WorkspaceCore

public typealias WorkspaceFileKind = WorkspaceCore.WorkspaceFileKind

public struct WorkspaceFileSnapshot: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let relativePath: String
        public let kind: WorkspaceFileKind
        public let identity: String?
        public let contentModificationDate: Date?
        public let mutationExpectation: WorkspaceItemMutationExpectation?

        public init(
            relativePath: String,
            kind: WorkspaceFileKind,
            identity: String?,
            contentModificationDate: Date?,
            mutationExpectation: WorkspaceItemMutationExpectation? = nil
        ) {
            self.relativePath = Self.normalized(relativePath)
            self.kind = kind
            self.identity = identity
            self.contentModificationDate = contentModificationDate
            self.mutationExpectation = mutationExpectation
        }

        public var nodeID: WorkspaceFileNode.ID {
            WorkspaceDisplayNodeID.make(identity: identity, relativePath: relativePath)
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
    public let mutationExpectation: WorkspaceItemMutationExpectation?
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
        mutationExpectation: WorkspaceItemMutationExpectation? = nil,
        children: [WorkspaceFileNode] = []
    ) {
        self.id = id
        self.name = name
        self.relativePath = relativePath
        self.kind = kind
        self.contentModificationDate = contentModificationDate
        self.mutationExpectation = mutationExpectation
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
        WorkspaceCoreAdapter.reconcile(
            previous: previous,
            snapshot: snapshot,
            options: options
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

private extension WorkspaceFileNode {
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
