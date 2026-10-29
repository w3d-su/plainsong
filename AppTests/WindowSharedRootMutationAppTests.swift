import Foundation
import MarkdownCore
@testable import Plainsong
import WorkspaceKit
import XCTest

@MainActor
final class WindowSharedRootMutationAppTests: SharedRootAppTestCase {
    func testRenameRelocatesTheOtherWindowsSessionFencesSaveAndPreservesWindowTreesAndSearches() async throws {
        let root = try makeRoot("root", files: [
            "a.md": "alpha text", "posts/b.md": "beta text", "misc.txt": "not markdown",
        ])
        try await openPair(root: root)
        second.openWorkspaceFile(root.appendingPathComponent("posts/b.md"))
        let session = second.shownSession
        second.toggleShowAllFiles()
        await second.workspaceReloadTask?.value
        let directoryID = try XCTUnwrap(node("posts", in: primary)?.id)
        primary.setWorkspaceNodeExpanded(true, id: directoryID)
        second.setWorkspaceNodeExpanded(false, id: directoryID)
        primary.setWorkspaceSearchQuery(TextSearchQuery(pattern: "alpha"))
        second.setWorkspaceSearchQuery(TextSearchQuery(pattern: "beta"))
        try await waitUntil("both searches complete") {
            self.primary.workspaceSearchState.phase == .completed && self.second.workspaceSearchState
                .phase == .completed
        }
        let firstQueryGeneration = primary.workspaceSearchQueryGeneration
        let secondQueryGeneration = second.workspaceSearchQueryGeneration
        var fenced = false
        operationStore.onUpsert = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !fenced else { return }
                XCTAssertEqual(self.primary.workspaceMutationNamespaceDepth, 1)
                XCTAssertTrue(self.second.workspaceMutationWriteFences.contains(ObjectIdentifier(session)))
                do {
                    try self.second.saveCurrentDocument()
                    XCTFail("the other window must not save while relocation owns the namespace")
                } catch {}
                fenced = true
            }
        }
        let before = scanner.count(root)

        try primary.renameWorkspaceItem(id: XCTUnwrap(node("posts/b.md", in: primary)?.id), to: "renamed.md")
        await primary.workspaceReloadTask?.value

        XCTAssertTrue(fenced)
        XCTAssertEqual(scanner.count(root), before + 1)
        XCTAssertTrue(second.shownSession === session)
        XCTAssertEqual(session.fileURL?.lastPathComponent, "renamed.md")
        XCTAssertEqual(primary.workspaceTree?.selectedNode?.relativePath, "a.md")
        XCTAssertEqual(second.workspaceTree?.selectedNode?.relativePath, "posts/renamed.md")
        XCTAssertTrue(primary.workspaceTree?.expandedNodeIDs.contains(directoryID) == true)
        XCTAssertFalse(second.workspaceTree?.expandedNodeIDs.contains(directoryID) == true)
        XCTAssertNil(node("misc.txt", in: primary))
        XCTAssertNotNil(node("misc.txt", in: second))
        XCTAssertFalse(primary.showAllFiles)
        XCTAssertTrue(second.showAllFiles)
        XCTAssertEqual(primary.workspaceSearchState.activeQuery?.pattern, "alpha")
        XCTAssertEqual(second.workspaceSearchState.activeQuery?.pattern, "beta")
        XCTAssertGreaterThan(primary.workspaceSearchQueryGeneration, firstQueryGeneration)
        XCTAssertGreaterThan(second.workspaceSearchQueryGeneration, secondQueryGeneration)
        XCTAssertNil(primary.presentedError)
        XCTAssertNil(second.presentedError)
    }

    func testRefreshKeepsEachWindowsMissingAndPresentDocumentDisposition() async throws {
        let root = try makeRoot("root")
        try await openPair(root: root)
        second.openWorkspaceFile(root.appendingPathComponent("b.md"))
        let missingSession = second.shownSession
        try FileManager.default.removeItem(at: root.appendingPathComponent("b.md"))
        primary.refreshWorkspaceAfterFileSystemChange()
        await primary.workspaceReloadTask?.value
        XCTAssertEqual(primary.workspaceTree?.selectedNode?.relativePath, "a.md")
        XCTAssertNil(second.workspaceTree?.selectedNode)
        XCTAssertTrue(second.shownSession === missingSession)
        let missingURL = try XCTUnwrap(second.sessionStateURL(for: missingSession))
        XCTAssertTrue(second.detachedSessionURLs.contains(missingURL))
    }

    func testOneWindowsInvalidDocumentDoesNotBlockTheRemainingRefreshRecipients() async throws {
        let root = try makeRoot("root", files: ["a.md": "alpha", "b.md": "beta", "c.md": "gamma"])
        try await openPair(root: root)
        second.openWorkspaceFile(root.appendingPathComponent("b.md"))
        let third = primary.makeSiblingFacade(admitsFileOperations: true)
        try third.openWorkspace(url: root, rememberAsLastOpened: false)
        third.openWorkspaceFile(root.appendingPathComponent("c.md"))
        try await waitUntil("third window selects its document") {
            third.workspaceTree?.selectedNode?.relativePath == "c.md"
        }
        let thirdSession = third.shownSession
        let thirdURL = try XCTUnwrap(third.sessionStateURL(for: thirdSession))
        try FileManager.default.removeItem(at: root.appendingPathComponent("b.md"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("b.md"),
            withIntermediateDirectories: false
        )
        try FileManager.default.removeItem(at: root.appendingPathComponent("c.md"))
        try Data("delta".utf8).write(to: root.appendingPathComponent("d.md"))
        let before = scanner.count(root)

        primary.refreshWorkspaceAfterFileSystemChange()
        await primary.workspaceReloadTask?.value

        XCTAssertNotNil(second.presentedError)
        XCTAssertNil(primary.presentedError)
        XCTAssertNil(third.presentedError)
        XCTAssertEqual(scanner.count(root), before + 1)
        XCTAssertNotNil(node("d.md", in: third))
        XCTAssertTrue(third.shownSession === thirdSession)
        XCTAssertNil(third.workspaceTree?.selectedNode)
        XCTAssertTrue(third.detachedSessionURLs.contains(thirdURL))
    }

    func testR2WatcherEventsDuringR1MutationDrainEveryPendingRoot() async throws {
        let root1 = try makeRoot("r1")
        let root2 = try makeRoot("r2")
        let root3 = try makeRoot("r3")
        let third = primary.makeSiblingFacade(admitsFileOperations: true)
        try await open(primary, root: root1)
        try await open(second, root: root2)
        try await open(third, root: root3)
        let counts = [scanner.count(root1), scanner.count(root2), scanner.count(root3)]
        try primary.beginWorkspaceNamespaceMutation([primary.shownSession])
        try Data("r2 new".utf8).write(to: root2.appendingPathComponent("new.md"))
        try Data("r3 new".utf8).write(to: root3.appendingPathComponent("new.md"))
        second.refreshWorkspaceAfterFileSystemChange()
        third.refreshWorkspaceAfterFileSystemChange()
        XCTAssertTrue(second.workspaceMutationRefreshPending)
        XCTAssertTrue(third.workspaceMutationRefreshPending)
        XCTAssertTrue(second.workspaceMutationRefreshRootAuthority == second.workspaceSearchRootAuthority)
        XCTAssertTrue(third.workspaceMutationRefreshRootAuthority == third.workspaceSearchRootAuthority)
        primary.drainWorkspaceMutationRefreshIfNeeded()
        XCTAssertTrue(second.workspaceMutationRefreshPending, "drain cannot consume an active transaction's queue")

        primary.endWorkspaceNamespaceMutation([primary.shownSession])
        primary.drainWorkspaceMutationRefreshIfNeeded()
        await primary.workspaceReloadTask?.value
        await second.workspaceReloadTask?.value
        await third.workspaceReloadTask?.value
        XCTAssertEqual(scanner.count(root1), counts[0] + 1)
        XCTAssertEqual(scanner.count(root2), counts[1] + 1)
        XCTAssertEqual(scanner.count(root3), counts[2] + 1)
        XCTAssertNotNil(node("new.md", in: second))
        XCTAssertNotNil(node("new.md", in: third))
        XCTAssertFalse(second.workspaceMutationRefreshPending)
        XCTAssertFalse(third.workspaceMutationRefreshPending)
        XCTAssertNil(second.workspaceMutationRefreshRootAuthority)
        XCTAssertNil(third.workspaceMutationRefreshRootAuthority)
    }

    func testNamespaceTransactionIsGlobalWhileImagePlacementCountStaysPerRoot() async throws {
        let root1 = try makeRoot("r1")
        let root2 = try makeRoot("r2")
        try await open(primary, root: root1)
        try await open(second, root: root2)
        second.workspaceImageAssetInsertionCount = 1
        XCTAssertEqual(primary.workspaceImageAssetInsertionCount, 0)
        try primary.beginWorkspaceNamespaceMutation([primary.shownSession])
        XCTAssertThrowsError(try second.beginWorkspaceNamespaceMutation([second.shownSession])) { error in
            guard case WorkspaceMutationError.operationAlreadyInProgress = error else {
                return XCTFail("expected global namespace refusal, got \(error)")
            }
        }
        primary.endWorkspaceNamespaceMutation([primary.shownSession])
        primary.drainWorkspaceMutationRefreshIfNeeded()
        XCTAssertThrowsError(try second.beginWorkspaceNamespaceMutation([second.shownSession])) { error in
            guard case WorkspaceMutationError.imageInsertionInProgress = error else {
                return XCTFail("expected per-root image placement refusal, got \(error)")
            }
        }
        second.workspaceImageAssetInsertionCount = 0
    }
}
