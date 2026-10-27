import Combine
import MarkdownCore
@testable import Plainsong
import WorkspaceKit
import XCTest

/// Phase 3 publish hygiene: work that leaves App-visible state unchanged must not publish.
@MainActor
final class AppPublishHygieneTests: XCTestCase {
    // MARK: - Completion workspace

    func testBodyEditRepublishesCompletionWorkspaceOnlyWhenItsValueChanges() async throws {
        let fixture = try makeCompletionFixture(postText: "# Title\n\nBody")
        let appState = fixture.appState
        appState.scheduleCompletionWorkspaceRefresh()
        await appState.completionWorkspaceTask?.value
        XCTAssertEqual(appState.completionWorkspace.currentFileHeadingAnchors, ["#title"])

        var publishCount = 0
        let probe = appState.windowState.$completionWorkspace.dropFirst().sink { _ in publishCount += 1 }
        defer { probe.cancel() }

        appState.replaceDocumentText("# Title\n\nBody, edited")
        await appState.completionWorkspaceTask?.value
        XCTAssertEqual(publishCount, 0, "A body edit leaves completion metadata unchanged")

        appState.replaceDocumentText("# Title\n\nBody, edited\n\n## Added")
        await appState.completionWorkspaceTask?.value
        XCTAssertEqual(publishCount, 1)
        XCTAssertEqual(appState.completionWorkspace.currentFileHeadingAnchors, ["#title", "#added"])
    }

    func testSiblingFrontmatterIsReadOncePerInstalledCapture() async throws {
        let fixture = try makeCompletionFixture(postText: "Body")
        let appState = fixture.appState
        appState.scheduleCompletionWorkspaceRefresh()
        await appState.completionWorkspaceTask?.value
        XCTAssertEqual(appState.completionWorkspace.frontmatterKeys, ["first_key"])

        // Not read again while the same capture is installed: typing reuses the cached base.
        try "---\nsecond_key: yes\n---\n".write(
            to: fixture.root.appendingPathComponent("sibling.md"),
            atomically: true,
            encoding: .utf8
        )
        appState.replaceDocumentText("Body, edited")
        await appState.completionWorkspaceTask?.value
        XCTAssertEqual(appState.completionWorkspace.frontmatterKeys, ["first_key"])

        // A newly installed capture reads the siblings again.
        appState.workspaceGeneration += 1
        appState.workspaceInstalledCaptureGeneration = appState.workspaceGeneration
        appState.scheduleCompletionWorkspaceRefresh()
        await appState.completionWorkspaceTask?.value
        XCTAssertEqual(appState.completionWorkspace.frontmatterKeys, ["second_key"])
    }

    func testCompletionWorkspaceIdentityIsLiteral() {
        let composed = CompletionWorkspace(markdownFilePaths: ["caf\u{00E9}.md"])
        let decomposed = CompletionWorkspace(markdownFilePaths: ["cafe\u{0301}.md"])

        XCTAssertEqual(composed, decomposed, "Precondition: `==` is canonical equivalence")
        XCTAssertFalse(composed.isLiterallyIdentical(to: decomposed))
        XCTAssertTrue(composed.isLiterallyIdentical(to: composed))
        XCTAssertFalse(
            CompletionWorkspace(currentFilePath: nil)
                .isLiterallyIdentical(to: CompletionWorkspace(currentFilePath: "a.md"))
        )
    }

    // MARK: - Find chrome

    func testIdenticalFindChromePublishesNothing() {
        let appState = AppState(
            currentDocument: DocumentSession(text: "alpha", fileKind: .markdown),
            shouldRestoreLastOpenedFile: false
        )
        var publishCount = 0
        let probe = appState.objectWillChange.sink { _ in publishCount += 1 }
        defer { probe.cancel() }

        XCTAssertFalse(appState.setEditorFindUI(appState.editorFindHost.ui))
        XCTAssertEqual(publishCount, 0)

        var ui = appState.editorFindHost.ui
        ui.queryText = "caf\u{00E9}"
        XCTAssertTrue(appState.setEditorFindUI(ui))
        XCTAssertEqual(publishCount, 1)

        // Canonically equivalent but literally different: still a change.
        ui.queryText = "cafe\u{0301}"
        XCTAssertTrue(appState.setEditorFindUI(ui))
        XCTAssertEqual(publishCount, 2)
        XCTAssertEqual(Array(appState.editorFindHost.ui.queryText.utf8), Array("cafe\u{0301}".utf8))
    }

    // MARK: - Inspector frontmatter

    func testFrontmatterDeterminingPrefixParsesLikeTheWholeText() {
        let cases = [
            "",
            "Body only",
            "---",
            "---\n",
            "----\ntitle: x\n---\n",
            "---x\n",
            "---\ntitle: A\n---\nBody\n",
            "---\r\ntitle: A\r\n---\r\nBody\r\n",
            "---\r\ntitle: A\r\n---",
            "---\ntitle: A\n---",
            "---\n---\nBody",
            "---\rtitle: A\r---\rBody",
            "---\ntitle: A\rnote: b\r---\nmore: c\n---\nBody",
            "---\ntitle: [unclosed\n---\nBody",
            "---\ntitle: A\nno closing delimiter\n",
            "---\ntags:\n  - a\n  - b\ndraft: true\ndate: 2026-10-22\n---\n# Heading\n",
            "---\ntitle: \"caf\u{00E9}\"\n---\ncafe\u{0301}",
            "---\n  ---\n---\nBody",
        ]
        for text in cases {
            let prefix = FrontmatterParseMemo.determiningPrefix(of: text)
            XCTAssertTrue(text.utf8.starts(with: prefix.utf8), "prefix of \(text.debugDescription)")
            XCTAssertEqual(
                Frontmatter.parse(prefix),
                Frontmatter.parse(text),
                "parse result for \(text.debugDescription)"
            )
        }
    }

    func testFrontmatterMemoSkipsTheParseWhileOnlyTheBodyChanges() {
        let memo = FrontmatterParseMemo()
        XCTAssertTrue(memo.update(text: "---\ntitle: A\n---\nBody"))
        XCTAssertEqual(memo.parseCount, 1)
        XCTAssertEqual(memo.result.block?.fields.map(\.key), ["title"])

        XCTAssertFalse(memo.update(text: "---\ntitle: A\n---\nBody, much longer now"))
        XCTAssertEqual(memo.parseCount, 1, "Body edits keep the parsed frontmatter")

        XCTAssertTrue(memo.update(text: "---\ntitle: B\n---\nBody"))
        XCTAssertEqual(memo.parseCount, 2)
        XCTAssertEqual(memo.result.block?.fields.first?.value, .string("B"))
    }

    // MARK: - Files rows

    func testTreeRowEqualityTracksSubtreeAndExpansionButNotActions() {
        let file = WorkspaceFileNode(
            id: "f",
            name: "a.md",
            relativePath: "dir/a.md",
            kind: .markdown,
            contentModificationDate: nil
        )
        let directory = WorkspaceFileNode(
            id: "d",
            name: "dir",
            relativePath: "dir",
            kind: .directory,
            contentModificationDate: nil,
            children: [file]
        )
        func row(
            _ node: WorkspaceFileNode,
            expanded: Set<WorkspaceFileNode.ID> = [],
            onFileClick: @escaping (WorkspaceFileNode.ID) -> Void = { _ in }
        ) -> WorkspaceTreeNodeRow {
            WorkspaceTreeNodeRow(
                node: node,
                rootURL: URL(fileURLWithPath: "/tmp/root", isDirectory: true),
                expandedNodeIDs: expanded,
                actions: WorkspaceTreeRowActions(
                    setExpanded: { _, _ in },
                    rename: { _ in },
                    create: { _, _ in },
                    fileClick: onFileClick,
                    trash: { _ in },
                    move: { _, _ in }
                )
            )
        }

        XCTAssertEqual(row(directory), row(directory, onFileClick: { _ in XCTFail("not called") }))
        XCTAssertNotEqual(row(directory), row(directory, expanded: ["d"]))
        var renamedChild = directory
        renamedChild.children = [WorkspaceFileNode(
            id: "f",
            name: "b.md",
            relativePath: "dir/b.md",
            kind: .markdown,
            contentModificationDate: nil
        )]
        XCTAssertNotEqual(row(directory), row(renamedChild))
    }

    // MARK: - Fixtures

    private struct CompletionFixture {
        let root: URL
        let appState: AppState
    }

    /// A workspace capture installed directly (no watcher), like a finished reload.
    private func makeCompletionFixture(postText: String) throws -> CompletionFixture {
        let root = try makeTemporaryDirectory()
        let post = root.appendingPathComponent("post.md")
        try postText.write(to: post, atomically: true, encoding: .utf8)
        try "---\nfirst_key: yes\n---\nBody".write(
            to: root.appendingPathComponent("sibling.md"),
            atomically: true,
            encoding: .utf8
        )
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let location = try authority.location(relativePath: "post.md")
        let loaded = try MarkdownFileStore().loadResult(at: location)
        let session = DocumentSession(text: postText, url: post, fileKind: .markdown)
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        appState.workspaceRootURL = root
        appState.workspaceSnapshot = WorkspaceFileSnapshot(entries: ["post.md", "sibling.md"].map {
            WorkspaceFileSnapshot.Entry(
                relativePath: $0,
                kind: .markdown,
                identity: $0,
                contentModificationDate: nil
            )
        })
        appState.workspaceSearchRootAuthority = authority
        appState.workspaceGeneration = 2
        appState.workspaceInstalledCaptureGeneration = 2
        appState.anchoredSessionFileBindings[ObjectIdentifier(session)] =
            AnchoredWorkspaceSessionFileBinding(
                location: location,
                identity: loaded.metadata.identity,
                sha256Digest: loaded.sha256Digest
            )
        addTeardownBlock { @MainActor in
            appState.completionWorkspaceTask?.cancel()
            appState.autosaveTask?.cancel()
            appState.statisticsTask?.cancel()
            try? FileManager.default.removeItem(at: root)
        }
        return CompletionFixture(root: root, appState: appState)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlainsongAppPublishHygieneTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try WorkspaceFileSystemRootAuthority(rootURL: url).canonicalRootURL
    }
}
