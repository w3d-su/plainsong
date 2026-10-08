import Foundation
import WorkspaceCore
import XCTest

final class WorkspaceSnapshotRejectionTests: XCTestCase {
    func testUnavailableEntryStaysInTheTree() {
        let entry = makeEntry(
            "offline.md",
            workspace: rootA,
            generation: 1,
            availability: .unavailable
        )
        let tree = requireApplied(
            WorkspaceSnapshotReconciler.reconcile(
                previous: nil,
                snapshot: snapshot(workspace: rootA, generation: 1, entries: [entry])
            )
        )?.0
        XCTAssertEqual(tree?.root.children.map(\.relativeSpelling), ["offline.md"])
        XCTAssertEqual(tree?.root.children.first?.availability, .unavailable)
    }

    func testInvalidSnapshotPathsAreOmittedWithoutLaundering() {
        let hostileParent = makeEntry(
            "/etc",
            workspace: rootA,
            generation: 1,
            kind: .directory,
            children: [makeEntry("etc/a.md", workspace: rootA, generation: 1)]
        )
        let entries = [
            makeEntry("/etc/a.md", workspace: rootA, generation: 1),
            makeEntry("foo/../../etc/passwd", workspace: rootA, generation: 1),
            makeEntry("", workspace: rootA, generation: 1),
            makeEntry("a\u{0}b.md", workspace: rootA, generation: 1),
            makeEntry("kept.md", workspace: rootA, generation: 1, fileName: "other.md"),
            hostileParent,
        ]
        let tree = requireApplied(
            WorkspaceSnapshotReconciler.reconcile(
                previous: nil,
                snapshot: snapshot(workspace: rootA, generation: 1, entries: entries)
            )
        )?.0
        let spellings = tree?.root.children.flatMap(spellings) ?? []

        XCTAssertEqual(spellings, ["kept.md"])
        XCTAssertFalse(spellings.contains("etc/a.md"))
        XCTAssertFalse(spellings.contains("/etc/a.md"))
    }

    func testCanonicalSpellingsAndDuplicateResourcesStayDistinct() {
        let nfc = "caf\u{00E9}.md"
        let nfd = "cafe\u{0301}.md"
        let shared = Data("shared".utf8)
        let tree = requireApplied(
            WorkspaceSnapshotReconciler.reconcile(
                previous: nil,
                snapshot: snapshot(workspace: rootA, generation: 1, entries: [
                    makeEntry(nfc, workspace: rootA, generation: 1),
                    makeEntry(nfd, workspace: rootA, generation: 1),
                    makeEntry("first.md", workspace: rootA, generation: 1, resource: shared),
                    makeEntry("second.md", workspace: rootA, generation: 1, resource: shared),
                ])
            )
        )?.0
        let children = tree?.root.children ?? []

        XCTAssertEqual(children.map(\.relativeSpelling), [nfd, nfc, "first.md", "second.md"])
        XCTAssertEqual(Set(children.compactMap(\.stabilityKey)).count, 4)
    }

    func testEntryFromAnotherRootOrOlderGenerationIsOmitted() {
        let foreign = makeEntry("foreign.md", workspace: rootB, generation: 3)
        let staleChild = makeEntry("stale.md", workspace: rootA, generation: 2)
        let current = makeEntry(
            "current",
            workspace: rootA,
            generation: 3,
            kind: .directory,
            children: [staleChild, makeEntry("current/live.md", workspace: rootA, generation: 3)]
        )
        let tree = requireApplied(
            WorkspaceSnapshotReconciler.reconcile(
                previous: nil,
                snapshot: snapshot(workspace: rootA, generation: 3, entries: [foreign, current])
            )
        )?.0

        XCTAssertEqual(tree?.root.children.map(\.relativeSpelling), ["current"])
        XCTAssertEqual(tree?.root.children.first?.children.map(\.relativeSpelling), ["current/live.md"])
    }

    func testNodeSpellingComesFromRelativePathRatherThanFileURL() {
        let entry = makeEntry(
            "kept.md",
            workspace: rootA,
            generation: 1,
            fileName: "resolved-elsewhere.md"
        )
        let tree = requireApplied(
            WorkspaceSnapshotReconciler.reconcile(
                previous: nil,
                snapshot: snapshot(workspace: rootA, generation: 1, entries: [entry])
            )
        )?.0
        XCTAssertEqual(tree?.root.children.first?.relativeSpelling, "kept.md")
        XCTAssertEqual(tree?.root.location, .root)
        XCTAssertNil(tree?.root.stabilityKey)
    }

    private let rootA = WorkspaceSnapshotFixtures.rootA
    private let rootB = WorkspaceSnapshotFixtures.rootB

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
        WorkspaceSnapshotFixtures.snapshot(workspace: workspace, generation: generation, entries: entries)
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

    private func spellings(_ node: WorkspacePortableNode) -> [String] {
        WorkspaceSnapshotFixtures.spellings(node)
    }
}
