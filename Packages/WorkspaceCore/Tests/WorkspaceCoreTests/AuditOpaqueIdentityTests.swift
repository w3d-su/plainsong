import Foundation
import WorkspaceCore
import XCTest

final class AuditOpaqueIdentityTests: XCTestCase {
    func testDuplicateEncodingCannotCollideWithUniqueOpaqueIdentity() throws {
        let workspace = WorkspaceSnapshotFixtures.rootA
        let duplicate = Data("a".utf8)
        var crafted = duplicate
        crafted.append(31)
        crafted.append(contentsOf: "p.md".utf8)
        let entries = [
            WorkspaceSnapshotFixtures.makeEntry("p.md", workspace: workspace, generation: 1, resource: duplicate),
            WorkspaceSnapshotFixtures.makeEntry("q.md", workspace: workspace, generation: 1, resource: duplicate),
            WorkspaceSnapshotFixtures.makeEntry("z.md", workspace: workspace, generation: 1, resource: crafted),
        ]
        let result = WorkspaceSnapshotReconciler.reconcile(
            previous: nil,
            snapshot: WorkspaceSnapshotFixtures.snapshot(workspace: workspace, generation: 1, entries: entries)
        )
        let applied = try XCTUnwrap(WorkspaceSnapshotFixtures.requireApplied(result))
        let keys = applied.0.root.children.compactMap(\.stabilityKey)
        XCTAssertEqual(keys.count, 3)
        XCTAssertEqual(Set(keys).count, 3, "Opaque resource ID encoding must be injective")
    }
}
