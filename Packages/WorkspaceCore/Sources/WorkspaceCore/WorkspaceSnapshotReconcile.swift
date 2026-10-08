import Foundation

/// Display stability for expansion and selection.
///
/// A unique provider resource id follows a rename inside one root. Without one,
/// the key is the root-relative UTF-8 path and does not follow a rename.
/// The same key in another root is not the same selection: callers must also
/// match `IOSWorkspaceIdentity`. Duplicate resource ids stay distinct by path.
public struct WorkspaceNodeStabilityKey: Hashable, Sendable {
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) {
        self.bytes = bytes
    }
}

/// UI state bound to one root generation. Node UUIDs are not this identity.
public struct WorkspaceExpansionState: Equatable, Sendable {
    public let workspaceID: IOSWorkspaceIdentity
    public let accessGeneration: UInt64
    public let expandedKeys: Set<WorkspaceNodeStabilityKey>
    public let selectedKey: WorkspaceNodeStabilityKey?

    public init(
        workspaceID: IOSWorkspaceIdentity,
        accessGeneration: UInt64,
        expandedKeys: Set<WorkspaceNodeStabilityKey>,
        selectedKey: WorkspaceNodeStabilityKey?
    ) {
        self.workspaceID = workspaceID
        self.accessGeneration = accessGeneration
        self.expandedKeys = expandedKeys
        self.selectedKey = selectedKey
    }
}

public struct WorkspacePortableNode: Equatable, Sendable {
    public let stabilityKey: WorkspaceNodeStabilityKey?
    public let entryID: UUID?
    public let location: WorkspaceTreeLocation
    public let kind: IOSWorkspaceEntry.Kind?
    public let availability: IOSFileAvailability?
    public let resourceID: IOSWorkspaceResourceIdentity?
    public let children: [WorkspacePortableNode]

    public init(
        stabilityKey: WorkspaceNodeStabilityKey?,
        entryID: UUID?,
        location: WorkspaceTreeLocation,
        kind: IOSWorkspaceEntry.Kind?,
        availability: IOSFileAvailability?,
        resourceID: IOSWorkspaceResourceIdentity?,
        children: [WorkspacePortableNode]
    ) {
        self.stabilityKey = stabilityKey
        self.entryID = entryID
        self.location = location
        self.kind = kind
        self.availability = availability
        self.resourceID = resourceID
        self.children = children
    }

    public var relativeSpelling: String? {
        location.relativeSpelling
    }
}

public struct WorkspacePortableTree: Equatable, Sendable {
    public let workspaceID: IOSWorkspaceIdentity
    public let accessGeneration: UInt64
    public let requestID: UUID
    public let root: WorkspacePortableNode

    public init(
        workspaceID: IOSWorkspaceIdentity,
        accessGeneration: UInt64,
        requestID: UUID,
        root: WorkspacePortableNode
    ) {
        self.workspaceID = workspaceID
        self.accessGeneration = accessGeneration
        self.requestID = requestID
        self.root = root
    }

    public func node(stabilityKey: WorkspaceNodeStabilityKey) -> WorkspacePortableNode? {
        root.first(stabilityKey: stabilityKey)
    }

    public func stabilityKeys() -> Set<WorkspaceNodeStabilityKey> {
        var keys: Set<WorkspaceNodeStabilityKey> = []
        root.collectStabilityKeys(into: &keys)
        return keys
    }
}

public enum WorkspaceSnapshotApplication: Equatable, Sendable {
    /// A current snapshot for this root, or a different root with empty UI state.
    case applied(WorkspacePortableTree, WorkspaceExpansionState)
    /// `snapshot` is older than the UI state's generation. The tree is unchanged.
    case rejectedStaleGeneration(WorkspaceExpansionState)
}

public enum WorkspaceSnapshotReconciler {
    public static func reconcile(
        previous: WorkspaceExpansionState?,
        snapshot: IOSWorkspaceSnapshot
    ) -> WorkspaceSnapshotApplication {
        if let previous,
           previous.workspaceID == snapshot.workspaceID,
           snapshot.accessGeneration < previous.accessGeneration
        {
            return .rejectedStaleGeneration(previous)
        }

        let tree = makeTree(snapshot)
        guard let previous, previous.workspaceID == snapshot.workspaceID else {
            return .applied(tree, emptyState(for: snapshot))
        }

        let keys = tree.stabilityKeys()
        let state = WorkspaceExpansionState(
            workspaceID: snapshot.workspaceID,
            accessGeneration: snapshot.accessGeneration,
            expandedKeys: previous.expandedKeys.intersection(keys),
            selectedKey: previous.selectedKey.flatMap { keys.contains($0) ? $0 : nil }
        )
        return .applied(tree, state)
    }

    private static func emptyState(for snapshot: IOSWorkspaceSnapshot) -> WorkspaceExpansionState {
        WorkspaceExpansionState(
            workspaceID: snapshot.workspaceID,
            accessGeneration: snapshot.accessGeneration,
            expandedKeys: [],
            selectedKey: nil
        )
    }

    private static func makeTree(_ snapshot: IOSWorkspaceSnapshot) -> WorkspacePortableTree {
        let drafts = validate(snapshot.entries, snapshot: snapshot)
        let keyed = assignKeys(drafts, counts: materialCounts(drafts))
        let root = WorkspacePortableNode(
            stabilityKey: nil,
            entryID: nil,
            location: .root,
            kind: nil,
            availability: nil,
            resourceID: nil,
            children: nodes(from: keyed)
        )
        return WorkspacePortableTree(
            workspaceID: snapshot.workspaceID,
            accessGeneration: snapshot.accessGeneration,
            requestID: snapshot.requestID,
            root: root
        )
    }

    private static func validate(
        _ entries: [IOSWorkspaceEntry],
        snapshot: IOSWorkspaceSnapshot
    ) -> [PathDraft] {
        var drafts: [PathDraft] = []
        for entry in entries {
            guard entry.location.workspaceID == snapshot.workspaceID,
                  entry.location.accessGeneration == snapshot.accessGeneration,
                  let path = WorkspaceRelativePath(spelling: entry.location.relativePath)
            else {
                continue
            }
            drafts.append(
                PathDraft(
                    entry: entry,
                    path: path,
                    children: validate(entry.children, snapshot: snapshot)
                )
            )
        }
        return drafts
    }

    private static func materialCounts(_ drafts: [PathDraft]) -> [[UInt8]: Int] {
        var counts: [[UInt8]: Int] = [:]
        func walk(_ drafts: [PathDraft]) {
            for draft in drafts {
                counts[rawMaterial(of: draft), default: 0] += 1
                walk(draft.children)
            }
        }
        walk(drafts)
        return counts
    }

    private static func assignKeys(
        _ drafts: [PathDraft],
        counts: [[UInt8]: Int]
    ) -> [KeyedDraft] {
        drafts.map { draft in
            let material = rawMaterial(of: draft)
            var bytes = material
            if counts[material, default: 0] > 1 {
                bytes.append(31)
                bytes.append(contentsOf: draft.path.byteKey.bytes)
            }
            return KeyedDraft(
                entry: draft.entry,
                path: draft.path,
                stabilityKey: WorkspaceNodeStabilityKey(bytes: bytes),
                children: assignKeys(draft.children, counts: counts)
            )
        }
    }

    private static func rawMaterial(of draft: PathDraft) -> [UInt8] {
        if let resourceID = draft.entry.location.resourceID {
            var bytes: [UInt8] = [1]
            bytes.append(contentsOf: resourceID.rawValue)
            return bytes
        }
        var bytes: [UInt8] = [0]
        bytes.append(contentsOf: draft.path.byteKey.bytes)
        return bytes
    }

    private static func nodes(from drafts: [KeyedDraft]) -> [WorkspacePortableNode] {
        drafts
            .sorted { lhs, rhs in
                WorkspacePathOrder.isBefore(lhs.path.spelling, rhs.path.spelling)
            }
            .map { draft in
                WorkspacePortableNode(
                    stabilityKey: draft.stabilityKey,
                    entryID: draft.entry.id,
                    location: .relative(draft.path),
                    kind: draft.entry.kind,
                    availability: draft.entry.availability,
                    resourceID: draft.entry.location.resourceID,
                    children: nodes(from: draft.children)
                )
            }
    }
}

private struct PathDraft {
    let entry: IOSWorkspaceEntry
    let path: WorkspaceRelativePath
    let children: [PathDraft]
}

private struct KeyedDraft {
    let entry: IOSWorkspaceEntry
    let path: WorkspaceRelativePath
    let stabilityKey: WorkspaceNodeStabilityKey
    let children: [KeyedDraft]
}

private extension WorkspacePortableNode {
    func first(stabilityKey: WorkspaceNodeStabilityKey) -> WorkspacePortableNode? {
        if self.stabilityKey == stabilityKey {
            return self
        }
        for child in children {
            if let found = child.first(stabilityKey: stabilityKey) {
                return found
            }
        }
        return nil
    }

    func collectStabilityKeys(into keys: inout Set<WorkspaceNodeStabilityKey>) {
        if let stabilityKey {
            keys.insert(stabilityKey)
        }
        for child in children {
            child.collectStabilityKeys(into: &keys)
        }
    }
}
