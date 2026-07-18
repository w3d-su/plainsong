@testable import WorkspaceKit
import XCTest

final class WorkspaceFileTreeTests: XCTestCase {
    func testDefaultFilterShowsMarkdownAndImagesButHidesOtherFiles() {
        let tree = WorkspaceFileTree.reconcile(
            previous: nil,
            snapshot: WorkspaceFileSnapshot(entries: [
                entry("README.md", kind: .markdown, identity: "readme"),
                entry("assets", kind: .directory, identity: "assets"),
                entry("assets/logo.png", kind: .image, identity: "logo"),
                entry("package.json", kind: .other, identity: "package"),
                entry("notes.txt", kind: .other, identity: "notes"),
            ]),
            options: .init(showAllFiles: false)
        )

        XCTAssertEqual(tree.root.children.map(\.relativePath), ["README.md", "assets"])
        XCTAssertEqual(tree.node(id: "assets")?.children.map(\.relativePath), ["assets/logo.png"])
    }

    func testShowAllFilesIncludesOtherFiles() {
        let tree = WorkspaceFileTree.reconcile(
            previous: nil,
            snapshot: WorkspaceFileSnapshot(entries: [
                entry("README.md", kind: .markdown, identity: "readme"),
                entry("package.json", kind: .other, identity: "package"),
            ]),
            options: .init(showAllFiles: true)
        )

        XCTAssertEqual(tree.root.children.map(\.relativePath), ["package.json", "README.md"])
    }

    func testExpansionIsPreservedWhenSiblingsChange() {
        var tree = WorkspaceFileTree.reconcile(
            previous: nil,
            snapshot: WorkspaceFileSnapshot(entries: [
                entry("content", kind: .directory, identity: "content"),
                entry("content/a.md", kind: .markdown, identity: "a"),
            ]),
            options: .init(showAllFiles: false)
        )
        tree.setExpanded(true, for: "content")

        let reconciled = WorkspaceFileTree.reconcile(
            previous: tree,
            snapshot: WorkspaceFileSnapshot(entries: [
                entry("content", kind: .directory, identity: "content"),
                entry("content/a.md", kind: .markdown, identity: "a"),
                entry("content/b.md", kind: .markdown, identity: "b"),
                entry("drafts.md", kind: .markdown, identity: "drafts"),
            ]),
            options: .init(showAllFiles: false)
        )

        XCTAssertTrue(reconciled.isExpanded("content"))
        XCTAssertEqual(reconciled.node(id: "content")?.children.map(\.relativePath), [
            "content/a.md",
            "content/b.md",
        ])
    }

    func testRenameKeepsSelectionWhenStableIdentityMatches() {
        var tree = WorkspaceFileTree.reconcile(
            previous: nil,
            snapshot: WorkspaceFileSnapshot(entries: [
                entry("posts", kind: .directory, identity: "posts"),
                entry("posts/old-title.md", kind: .markdown, identity: "file-42"),
            ]),
            options: .init(showAllFiles: false)
        )
        tree.selectNode(id: "file-42")

        let reconciled = WorkspaceFileTree.reconcile(
            previous: tree,
            snapshot: WorkspaceFileSnapshot(entries: [
                entry("posts", kind: .directory, identity: "posts"),
                entry("posts/new-title.md", kind: .markdown, identity: "file-42"),
            ]),
            options: .init(showAllFiles: false)
        )

        XCTAssertEqual(reconciled.selectedNode?.id, "file-42")
        XCTAssertEqual(reconciled.selectedNode?.relativePath, "posts/new-title.md")
    }

    func testTreePreservesSnapshotMutationExpectation() {
        let expectation = WorkspaceItemMutationExpectation(
            identity: WorkspaceFileSystemIdentity(device: 12, inode: 34),
            kind: .regularFile
        )
        let tree = WorkspaceFileTree.reconcile(
            previous: nil,
            snapshot: WorkspaceFileSnapshot(entries: [
                WorkspaceFileSnapshot.Entry(
                    relativePath: "post.md",
                    kind: .markdown,
                    identity: "post",
                    contentModificationDate: nil,
                    mutationExpectation: expectation
                ),
            ]),
            options: .init(showAllFiles: true)
        )

        XCTAssertEqual(tree.node(id: "post")?.mutationExpectation, expectation)
    }

    func testCanonicalEquivalentDirectorySpellingsKeepDistinctChildren() {
        let nfcDirectory = "caf\u{00E9}"
        let nfdDirectory = "cafe\u{0301}"
        let tree = WorkspaceFileTree.reconcile(
            previous: nil,
            snapshot: WorkspaceFileSnapshot(entries: [
                entry(nfcDirectory, kind: .directory, identity: "nfc-directory"),
                entry("\(nfcDirectory)/nfc.md", kind: .markdown, identity: "nfc-child"),
                entry(nfdDirectory, kind: .directory, identity: "nfd-directory"),
                entry("\(nfdDirectory)/nfd.md", kind: .markdown, identity: "nfd-child"),
            ]),
            options: .init(showAllFiles: true)
        )

        XCTAssertEqual(tree.root.children.map(\.id), ["nfd-directory", "nfc-directory"])
        XCTAssertEqual(tree.node(id: "nfc-directory")?.children.map(\.id), ["nfc-child"])
        XCTAssertEqual(tree.node(id: "nfd-directory")?.children.map(\.id), ["nfd-child"])
    }

    func testDefaultFilterUsesByteExactAncestorPaths() {
        let nfcDirectory = "caf\u{00E9}"
        let nfdDirectory = "cafe\u{0301}"
        let tree = WorkspaceFileTree.reconcile(
            previous: nil,
            snapshot: WorkspaceFileSnapshot(entries: [
                entry(nfcDirectory, kind: .directory, identity: "nfc-directory"),
                entry("\(nfcDirectory)/visible.md", kind: .markdown, identity: "visible"),
                entry(nfdDirectory, kind: .directory, identity: "nfd-directory"),
                entry("\(nfdDirectory)/hidden.txt", kind: .other, identity: "hidden"),
            ]),
            options: .init(showAllFiles: false)
        )

        XCTAssertEqual(tree.root.children.map(\.id), ["nfc-directory"])
        XCTAssertEqual(tree.node(id: "nfc-directory")?.children.map(\.id), ["visible"])
    }

    func testFallbackNodeIDsDistinguishCanonicalEquivalentPaths() {
        let nfcDirectory = "caf\u{00E9}"
        let nfdDirectory = "cafe\u{0301}"
        var tree = WorkspaceFileTree.reconcile(
            previous: nil,
            snapshot: WorkspaceFileSnapshot(entries: [
                entry(nfcDirectory, kind: .directory, identity: nil),
                entry(nfdDirectory, kind: .directory, identity: nil),
            ]),
            options: .init(showAllFiles: true)
        )
        let nodeIDs = tree.root.children.map(\.id)

        XCTAssertEqual(nodeIDs.count, 2)
        XCTAssertEqual(Set(nodeIDs).count, 2)
        tree.setExpanded(true, for: nodeIDs[0])
        XCTAssertTrue(tree.isExpanded(nodeIDs[0]))
        XCTAssertFalse(tree.isExpanded(nodeIDs[1]))
    }

    func testDuplicatePhysicalIdentitiesReceivePathDisambiguatedActionIDs() {
        let tree = WorkspaceFileTree.reconcile(
            previous: nil,
            snapshot: WorkspaceFileSnapshot(entries: [
                entry("first.md", kind: .markdown, identity: "shared-inode"),
                entry("second.md", kind: .markdown, identity: "shared-inode"),
            ]),
            options: .init(showAllFiles: true)
        )
        let nodes = tree.root.children

        XCTAssertEqual(nodes.map(\.relativePath), ["first.md", "second.md"])
        XCTAssertEqual(Set(nodes.map(\.id)).count, 2)
        for node in nodes {
            XCTAssertEqual(tree.node(id: node.id)?.relativePath, node.relativePath)
        }
    }

    func testReconcileTwoThousandFilesStaysUnderBudget() {
        let entries = (0 ..< 2000).map { index in
            entry(
                "content/post-\(String(format: "%04d", index)).md",
                kind: .markdown,
                identity: "post-\(index)"
            )
        } + [
            entry("content", kind: .directory, identity: "content"),
        ]

        let start = DispatchTime.now().uptimeNanoseconds
        _ = WorkspaceFileTree.reconcile(
            previous: nil,
            snapshot: WorkspaceFileSnapshot(entries: entries),
            options: .init(showAllFiles: false)
        )
        let elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000

        XCTAssertLessThan(elapsedSeconds, 0.05)
    }

    private func entry(
        _ relativePath: String,
        kind: WorkspaceFileKind,
        identity: String?
    ) -> WorkspaceFileSnapshot.Entry {
        WorkspaceFileSnapshot.Entry(
            relativePath: relativePath,
            kind: kind,
            identity: identity,
            contentModificationDate: nil
        )
    }
}
