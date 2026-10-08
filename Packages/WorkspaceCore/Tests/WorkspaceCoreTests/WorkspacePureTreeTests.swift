import Foundation
import WorkspaceCore
import XCTest

final class WorkspacePureTreeTests: XCTestCase {
    func testFilteredAncestorsRemainVisibleForNestedMarkdown() {
        let tree = WorkspacePureTree.reconcile(
            previousExpandedNodeIDs: [],
            previousSelectedNodeID: nil,
            entries: [
                row("a", kind: .directory, identity: "a"),
                row("a/b", kind: .directory, identity: "b"),
                row("a/b/c.md", kind: .markdown, identity: "c"),
                row("a/b/notes.txt", kind: .other, identity: "notes"),
                row("a/hidden", kind: .directory, identity: "hidden"),
                row("a/hidden/plain.txt", kind: .other, identity: "plain"),
                row("README.md", kind: .markdown, identity: "readme"),
            ],
            options: .init(showAllFiles: false)
        )

        XCTAssertEqual(tree.root.children.map(\.relativePath), ["README.md", "a"])
        XCTAssertEqual(tree.node(id: "a")?.children.map(\.relativePath), ["a/b"])
        XCTAssertEqual(tree.node(id: "b")?.children.map(\.relativePath), ["a/b/c.md"])
        XCTAssertNil(tree.node(id: "hidden"))
        XCTAssertNil(tree.node(id: "notes"))
    }

    func testFilteredAncestorsUseByteExactPaths() {
        let nfcDirectory = "caf\u{00E9}"
        let nfdDirectory = "cafe\u{0301}"
        let tree = WorkspacePureTree.reconcile(
            previousExpandedNodeIDs: [],
            previousSelectedNodeID: nil,
            entries: [
                row(nfcDirectory, kind: .directory, identity: "nfc-directory"),
                row("\(nfcDirectory)/visible.md", kind: .markdown, identity: "visible"),
                row(nfdDirectory, kind: .directory, identity: "nfd-directory"),
                row("\(nfdDirectory)/hidden.txt", kind: .other, identity: "hidden"),
            ],
            options: .init(showAllFiles: false)
        )

        XCTAssertEqual(tree.root.children.map(\.id), ["nfc-directory"])
        XCTAssertEqual(tree.node(id: "nfc-directory")?.children.map(\.id), ["visible"])
    }

    func testNumericSortPlacesTenAfterTwo() {
        let tree = showAll([
            row("posts/post-10.md", kind: .markdown, identity: "ten"),
            row("posts/post-2.md", kind: .markdown, identity: "two"),
            row("posts", kind: .directory, identity: "posts"),
        ])

        XCTAssertEqual(tree.node(id: "posts")?.children.map(\.relativePath), [
            "posts/post-2.md",
            "posts/post-10.md",
        ])
    }

    func testCaseInsensitiveTieBreaksByUTF8Bytes() {
        let tree = showAll([
            row("readme.md", kind: .markdown, identity: "lower"),
            row("Readme.md", kind: .markdown, identity: "upper"),
        ])

        XCTAssertEqual(tree.root.children.map(\.relativePath), ["Readme.md", "readme.md"])
    }

    func testNFCAndNFDPathsStayDistinctNodes() {
        let nfcDirectory = "caf\u{00E9}"
        let nfdDirectory = "cafe\u{0301}"
        let tree = showAll([
            row(nfcDirectory, kind: .directory, identity: "nfc-directory"),
            row("\(nfcDirectory)/nfc.md", kind: .markdown, identity: "nfc-child"),
            row(nfdDirectory, kind: .directory, identity: "nfd-directory"),
            row("\(nfdDirectory)/nfd.md", kind: .markdown, identity: "nfd-child"),
        ])

        XCTAssertEqual(tree.root.children.map(\.id), ["nfd-directory", "nfc-directory"])
        XCTAssertEqual(tree.node(id: "nfc-directory")?.children.map(\.id), ["nfc-child"])
        XCTAssertEqual(tree.node(id: "nfd-directory")?.children.map(\.id), ["nfd-child"])
    }

    func testSameIdentityDifferentPathsStayDistinct() {
        let tree = showAll([
            row("first.md", kind: .markdown, identity: "shared-inode", index: 0),
            row("second.md", kind: .markdown, identity: "shared-inode", index: 1),
        ])
        let nodes = tree.root.children

        XCTAssertEqual(nodes.map(\.relativePath), ["first.md", "second.md"])
        XCTAssertEqual(Set(nodes.map(\.id)).count, 2)
        XCTAssertEqual(nodes.map(\.sidecarIndex), [0, 1])
    }

    func testMissingIdentityUsesBytePathFallbackAndDoesNotTrackRename() {
        let nfcDirectory = "caf\u{00E9}"
        let nfdDirectory = "cafe\u{0301}"
        var tree = showAll([
            row(nfcDirectory, kind: .directory, identity: nil, index: 0),
            row(nfdDirectory, kind: .directory, identity: nil, index: 1),
        ])
        XCTAssertEqual(Set(tree.root.children.map(\.id)).count, 2)
        let nfcID = tree.root.children.first {
            WorkspacePathByteKey($0.relativePath) == WorkspacePathByteKey(nfcDirectory)
        }?.id
        XCTAssertNotNil(nfcID)
        tree.setExpanded(true, for: nfcID ?? "")
        tree.selectNode(id: nfcID)

        let renamed = WorkspacePureTree.reconcile(
            previousExpandedNodeIDs: tree.expandedNodeIDs,
            previousSelectedNodeID: tree.selectedNodeID,
            entries: [
                row("renamed", kind: .directory, identity: nil, index: 0),
                row(nfdDirectory, kind: .directory, identity: nil, index: 1),
            ],
            options: .init(showAllFiles: true)
        )
        XCTAssertNil(renamed.selectedNodeID)
        XCTAssertFalse(renamed.expandedNodeIDs.contains(nfcID ?? ""))
        XCTAssertEqual(
            renamed.root.children.first {
                WorkspacePathByteKey($0.relativePath) == WorkspacePathByteKey(nfdDirectory)
            }?.id,
            tree.root.children.first {
                WorkspacePathByteKey($0.relativePath) == WorkspacePathByteKey(nfdDirectory)
            }?.id
        )
    }

    func testSameRootKeepsSurvivingExpansionAndDropsDeletedSelection() {
        var tree = showAll([
            row("posts", kind: .directory, identity: "posts"),
            row("posts/old-title.md", kind: .markdown, identity: "file-42"),
        ])
        tree.setExpanded(true, for: "posts")
        tree.selectNode(id: "file-42")

        let reconciled = WorkspacePureTree.reconcile(
            previousExpandedNodeIDs: tree.expandedNodeIDs,
            previousSelectedNodeID: tree.selectedNodeID,
            entries: [
                row("posts", kind: .directory, identity: "posts"),
                row("posts/new-title.md", kind: .markdown, identity: "file-42"),
                row("gone.md", kind: .markdown, identity: "gone"),
            ],
            options: .init(showAllFiles: true)
        )
        XCTAssertTrue(reconciled.isExpanded("posts"))
        XCTAssertEqual(reconciled.selectedNodeID, "file-42")
        XCTAssertEqual(reconciled.node(id: "file-42")?.relativePath, "posts/new-title.md")

        let deleted = WorkspacePureTree.reconcile(
            previousExpandedNodeIDs: reconciled.expandedNodeIDs,
            previousSelectedNodeID: "gone",
            entries: [
                row("posts", kind: .directory, identity: "posts"),
            ],
            options: .init(showAllFiles: true)
        )
        XCTAssertNil(deleted.selectedNodeID)
        XCTAssertTrue(deleted.isExpanded("posts"))
    }

    func testAbsoluteSnapshotPathIsNotLaunderedIntoRootChild() {
        let tree = showAll([
            row("/etc/a.md", kind: .markdown, identity: "hostile"),
            row("notes.md", kind: .markdown, identity: "notes"),
        ])

        XCTAssertEqual(tree.root.children.map(\.relativePath), ["notes.md"])
        XCTAssertFalse(tree.root.children.contains { $0.relativePath == "etc/a.md" })
    }

    private func showAll(_ entries: [WorkspacePureEntry]) -> WorkspacePureTree {
        WorkspacePureTree.reconcile(
            previousExpandedNodeIDs: [],
            previousSelectedNodeID: nil,
            entries: entries,
            options: .init(showAllFiles: true)
        )
    }

    private func row(
        _ relativePath: String,
        kind: WorkspaceFileKind,
        identity: String?,
        index: Int? = nil
    ) -> WorkspacePureEntry {
        WorkspacePureEntry(
            relativePath: relativePath,
            kind: kind,
            identity: identity,
            contentModificationDate: nil,
            sidecarIndex: index ?? sidecarCounter(relativePath)
        )
    }

    private func sidecarCounter(_ relativePath: String) -> Int {
        relativePath.utf8.reduce(0) { partial, byte in partial + Int(byte) }
    }
}
