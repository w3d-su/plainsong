import Foundation
import WorkspaceCore
import XCTest

final class WorkspaceSnapshotReconcileTests: XCTestCase {
    private let rootA = IOSWorkspaceIdentity(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    )
    private let rootB = IOSWorkspaceIdentity(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    )
    private let sharedEntryID = UUID(uuidString: "00000000-0000-0000-0000-0000000000E1")!

    func testSameRootNewerGenerationKeepsSurvivingExpansionAndSelection() {
        let directory = makeEntry("posts", workspace: rootA, generation: 5, kind: .directory, id: directoryID)
        let file = makeEntry(
            "posts/old.md",
            workspace: rootA,
            generation: 5,
            resource: Data("file-42".utf8),
            id: fileID
        )
        let first = snapshot(workspace: rootA, generation: 5, entries: [
            withChildren(directory, children: [file]),
        ])
        let applied = requireApplied(WorkspaceSnapshotReconciler.reconcile(previous: nil, snapshot: first))
        let directoryKey = key(in: applied?.0, spelling: "posts")
        let fileKey = key(in: applied?.0, spelling: "posts/old.md")
        XCTAssertNotNil(directoryKey)
        XCTAssertNotNil(fileKey)
        let previous = WorkspaceExpansionState(
            workspaceID: rootA,
            accessGeneration: 5,
            expandedKeys: directoryKey.map { [$0] } ?? [],
            selectedKey: fileKey
        )

        let renamed = makeEntry(
            "posts/new.md",
            workspace: rootA,
            generation: 6,
            resource: Data("file-42".utf8),
            id: UUID()
        )
        let nextDirectory = makeEntry("posts", workspace: rootA, generation: 6, kind: .directory, id: UUID())
        let next = snapshot(workspace: rootA, generation: 6, entries: [
            withChildren(nextDirectory, children: [renamed]),
        ])
        let reconciled = requireApplied(
            WorkspaceSnapshotReconciler.reconcile(previous: previous, snapshot: next)
        )

        XCTAssertEqual(reconciled?.1.accessGeneration, 6)
        XCTAssertEqual(reconciled?.1.selectedKey, fileKey)
        XCTAssertEqual(reconciled?.1.expandedKeys, previous.expandedKeys)
        XCTAssertEqual(reconciled?.0.root.firstSpelling("posts/new.md")?.entryID == fileID, false)
        XCTAssertNotNil(reconciled?.0.root.firstSpelling("posts/new.md"))
    }

    func testDeletedNodeDropsSelection() {
        let file = makeEntry("gone.md", workspace: rootA, generation: 5, resource: Data("gone".utf8))
        let first = requireApplied(
            WorkspaceSnapshotReconciler.reconcile(
                previous: nil,
                snapshot: snapshot(workspace: rootA, generation: 5, entries: [file])
            )
        )
        let selected = first?.0.root.children.first?.stabilityKey
        let previous = WorkspaceExpansionState(
            workspaceID: rootA,
            accessGeneration: 5,
            expandedKeys: [],
            selectedKey: selected
        )
        let reconciled = requireApplied(
            WorkspaceSnapshotReconciler.reconcile(
                previous: previous,
                snapshot: snapshot(workspace: rootA, generation: 6, entries: [])
            )
        )

        XCTAssertNil(reconciled?.1.selectedKey)
        XCTAssertEqual(reconciled?.1.accessGeneration, 6)
    }

    func testSamePathAcrossRootsDoesNotInheritExpansionOrSelection() {
        let path = "notes.md"
        let resource = Data("same-resource".utf8)
        let firstEntry = makeEntry(
            path,
            workspace: rootA,
            generation: 4,
            resource: resource,
            id: sharedEntryID
        )
        let first = requireApplied(
            WorkspaceSnapshotReconciler.reconcile(
                previous: nil,
                snapshot: snapshot(workspace: rootA, generation: 4, entries: [firstEntry])
            )
        )
        let selected = first?.0.root.children.first?.stabilityKey
        XCTAssertNotNil(selected)
        let previous = WorkspaceExpansionState(
            workspaceID: rootA,
            accessGeneration: 4,
            expandedKeys: selected.map { [$0] } ?? [],
            selectedKey: selected
        )

        let other = makeEntry(
            path,
            workspace: rootB,
            generation: 9,
            resource: resource,
            id: sharedEntryID
        )
        let reconciled = requireApplied(
            WorkspaceSnapshotReconciler.reconcile(
                previous: previous,
                snapshot: snapshot(workspace: rootB, generation: 9, entries: [other])
            )
        )

        XCTAssertEqual(reconciled?.1.workspaceID, rootB)
        XCTAssertTrue(reconciled?.1.expandedKeys.isEmpty ?? false)
        XCTAssertNil(reconciled?.1.selectedKey)
        XCTAssertEqual(reconciled?.0.root.children.first?.relativeSpelling, path)
    }

    func testStaleGenerationDoesNotReconcile() {
        let previous = WorkspaceExpansionState(
            workspaceID: rootA,
            accessGeneration: 5,
            expandedKeys: [WorkspaceNodeStabilityKey(bytes: [9])],
            selectedKey: WorkspaceNodeStabilityKey(bytes: [7])
        )
        let stale = snapshot(
            workspace: rootA,
            generation: 4,
            entries: [makeEntry("other.md", workspace: rootA, generation: 4)]
        )

        let application = WorkspaceSnapshotReconciler.reconcile(previous: previous, snapshot: stale)
        guard case let .rejectedStaleGeneration(state) = application else {
            return XCTFail("expected stale generation to be rejected")
        }
        XCTAssertEqual(state, previous)
    }

    func testMissingResourceIdentityDoesNotTrackRename() {
        let original = requireApplied(
            WorkspaceSnapshotReconciler.reconcile(
                previous: nil,
                snapshot: snapshot(
                    workspace: rootA,
                    generation: 1,
                    entries: [makeEntry("old.md", workspace: rootA, generation: 1)]
                )
            )
        )
        let selected = original?.0.root.children.first?.stabilityKey
        let previous = WorkspaceExpansionState(
            workspaceID: rootA,
            accessGeneration: 1,
            expandedKeys: [],
            selectedKey: selected
        )
        let renamed = requireApplied(
            WorkspaceSnapshotReconciler.reconcile(
                previous: previous,
                snapshot: snapshot(
                    workspace: rootA,
                    generation: 2,
                    entries: [makeEntry("new.md", workspace: rootA, generation: 2)]
                )
            )
        )
        XCTAssertNil(renamed?.1.selectedKey)
        XCTAssertEqual(renamed?.0.root.children.first?.relativeSpelling, "new.md")
    }

    private let directoryID = WorkspaceSnapshotFixtures.directoryID
    private let fileID = WorkspaceSnapshotFixtures.fileID

    private func key(
        in tree: WorkspacePortableTree?,
        spelling: String
    ) -> WorkspaceNodeStabilityKey? {
        WorkspaceSnapshotFixtures.key(in: tree, spelling: spelling)
    }

    private func requireApplied(
        _ application: WorkspaceSnapshotApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> (WorkspacePortableTree, WorkspaceExpansionState)? {
        WorkspaceSnapshotFixtures.requireApplied(application, file: file, line: line)
    }

    private func snapshot(
        workspace: IOSWorkspaceIdentity,
        generation: UInt64,
        entries: [IOSWorkspaceEntry]
    ) -> IOSWorkspaceSnapshot {
        WorkspaceSnapshotFixtures.snapshot(
            workspace: workspace,
            generation: generation,
            entries: entries
        )
    }

    private func withChildren(
        _ entry: IOSWorkspaceEntry,
        children: [IOSWorkspaceEntry]
    ) -> IOSWorkspaceEntry {
        WorkspaceSnapshotFixtures.withChildren(entry, children: children)
    }

    private func makeEntry(
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
        WorkspaceSnapshotFixtures.makeEntry(
            path,
            workspace: workspace,
            generation: generation,
            kind: kind,
            resource: resource,
            availability: availability,
            children: children,
            id: id,
            fileName: fileName
        )
    }
}
