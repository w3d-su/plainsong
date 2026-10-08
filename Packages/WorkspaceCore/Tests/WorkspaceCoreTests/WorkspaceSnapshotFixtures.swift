import Foundation
import WorkspaceCore
import XCTest

enum WorkspaceSnapshotFixtures {
    static let rootA = IOSWorkspaceIdentity(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    )
    static let rootB = IOSWorkspaceIdentity(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    )
    static let directoryID = UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!
    static let fileID = UUID(uuidString: "00000000-0000-0000-0000-0000000000F1")!

    static func key(
        in tree: WorkspacePortableTree?,
        spelling: String
    ) -> WorkspaceNodeStabilityKey? {
        guard let tree else { return nil }
        return tree.root.firstSpelling(spelling)?.stabilityKey
    }

    static func requireApplied(
        _ application: WorkspaceSnapshotApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> (WorkspacePortableTree, WorkspaceExpansionState)? {
        guard case let .applied(tree, state) = application else {
            XCTFail("expected an applied snapshot", file: file, line: line)
            return nil
        }
        return (tree, state)
    }

    static func spellings(_ node: WorkspacePortableNode) -> [String] {
        let own = node.relativeSpelling.map { [$0] } ?? []
        return own + node.children.flatMap(Self.spellings)
    }

    static func snapshot(
        workspace: IOSWorkspaceIdentity,
        generation: UInt64,
        entries: [IOSWorkspaceEntry]
    ) -> IOSWorkspaceSnapshot {
        IOSWorkspaceSnapshot(
            workspaceID: workspace,
            accessGeneration: generation,
            requestID: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!,
            entries: entries
        )
    }

    static func withChildren(
        _ entry: IOSWorkspaceEntry,
        children: [IOSWorkspaceEntry]
    ) -> IOSWorkspaceEntry {
        IOSWorkspaceEntry(
            id: entry.id,
            location: entry.location,
            kind: entry.kind,
            availability: entry.availability,
            children: children
        )
    }

    static func makeEntry(
        _ path: String,
        workspace: IOSWorkspaceIdentity,
        generation: UInt64,
        kind: IOSWorkspaceEntry.Kind = .document(.markdown),
        resource: Data? = nil,
        availability: IOSFileAvailability = .available(canWrite: true),
        children: [IOSWorkspaceEntry] = [],
        id: UUID = UUID(),
        fileName: String? = nil
    ) -> IOSWorkspaceEntry {
        IOSWorkspaceEntry(
            id: id,
            location: IOSFileLocation(
                workspaceID: workspace,
                accessGeneration: generation,
                relativePath: path,
                fileURL: URL(fileURLWithPath: "/synthetic/\(fileName ?? "unused")"),
                resourceID: resource.map { IOSWorkspaceResourceIdentity(rawValue: $0) }
            ),
            kind: kind,
            availability: availability,
            children: children
        )
    }
}

extension WorkspacePortableNode {
    func firstSpelling(_ spelling: String) -> WorkspacePortableNode? {
        if relativeSpelling == spelling {
            return self
        }
        for child in children {
            if let found = child.firstSpelling(spelling) {
                return found
            }
        }
        return nil
    }
}
