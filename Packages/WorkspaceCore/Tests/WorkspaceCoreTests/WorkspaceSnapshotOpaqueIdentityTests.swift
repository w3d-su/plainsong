import Foundation
import WorkspaceCore
import XCTest

final class WorkspaceSnapshotOpaqueIdentityTests: XCTestCase {
    func testDuplicateEncodingCannotCollideWithUniqueOpaqueIdentity() throws {
        let duplicate = Data([0x61])
        let encodedLookingID = duplicate + Data([0x1F]) + Data("p.md".utf8)
        let tree = try tree(entries: [
            entry("p.md", resource: duplicate),
            entry("q.md", resource: duplicate),
            entry("unique.md", resource: encodedLookingID),
        ])

        XCTAssertEqual(tree.root.children.count, 3)
        XCTAssertEqual(tree.stabilityKeys().count, 3)
        for node in tree.root.children {
            let key = try XCTUnwrap(node.stabilityKey)
            XCTAssertEqual(tree.node(stabilityKey: key)?.entryID, node.entryID)
        }
    }

    func testArbitraryResourceBytesAndDuplicateFieldBoundariesRemainDistinct() throws {
        let resources = [Data(), Data([0]), Data([1]), Data([0x1F]), Data([0xFF, 0, 0x1F])]
        var entries: [IOSWorkspaceEntry] = []
        for (index, resource) in resources.enumerated() {
            entries.append(entry("p-\(index).md", resource: resource))
            entries.append(entry("q-\(index).md", resource: resource))
            entries.append(entry("unique-\(index).md", resource: resource + Data([0x1F]) + Data("p-\(index).md".utf8)))
        }
        let tree = try tree(entries: entries)
        XCTAssertEqual(tree.stabilityKeys().count, entries.count)
    }

    func testDeletingDuplicateDoesNotRetargetSelectionToEncodedLookingResource() throws {
        let duplicate = Data([0x61])
        let encodedLookingID = duplicate + Data([0x1F]) + Data("p.md".utf8)
        let first = try tree(entries: [
            entry("p.md", resource: duplicate),
            entry("q.md", resource: duplicate),
            entry("unique.md", resource: encodedLookingID),
        ])
        let selected = try XCTUnwrap(first.root.firstSpelling("p.md")?.stabilityKey)
        let previous = WorkspaceExpansionState(
            workspaceID: WorkspaceSnapshotFixtures.rootA,
            accessGeneration: 1,
            expandedKeys: [selected],
            selectedKey: selected
        )
        let next = WorkspaceSnapshotFixtures.snapshot(
            workspace: WorkspaceSnapshotFixtures.rootA, generation: 2,
            entries: [WorkspaceSnapshotFixtures.makeEntry(
                "unique.md", workspace: WorkspaceSnapshotFixtures.rootA,
                generation: 2, resource: encodedLookingID
            )]
        )
        let applied = try XCTUnwrap(WorkspaceSnapshotFixtures.requireApplied(
            WorkspaceSnapshotReconciler.reconcile(previous: previous, snapshot: next)
        ))
        XCTAssertNil(applied.1.selectedKey)
        XCTAssertTrue(applied.1.expandedKeys.isEmpty)
    }

    private func entry(_ path: String, resource: Data) -> IOSWorkspaceEntry {
        WorkspaceSnapshotFixtures.makeEntry(
            path, workspace: WorkspaceSnapshotFixtures.rootA,
            generation: 1, resource: resource
        )
    }

    private func tree(entries: [IOSWorkspaceEntry]) throws -> WorkspacePortableTree {
        let snapshot = WorkspaceSnapshotFixtures.snapshot(
            workspace: WorkspaceSnapshotFixtures.rootA, generation: 1, entries: entries
        )
        return try XCTUnwrap(WorkspaceSnapshotFixtures.requireApplied(
            WorkspaceSnapshotReconciler.reconcile(previous: nil, snapshot: snapshot)
        )).0
    }
}
