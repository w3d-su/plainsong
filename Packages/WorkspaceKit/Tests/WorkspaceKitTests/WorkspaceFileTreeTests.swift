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
        identity: String
    ) -> WorkspaceFileSnapshot.Entry {
        WorkspaceFileSnapshot.Entry(
            relativePath: relativePath,
            kind: kind,
            identity: identity,
            contentModificationDate: nil
        )
    }
}
