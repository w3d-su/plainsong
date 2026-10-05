import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import WorkspaceKit
import XCTest

@MainActor
final class EditorFindNavigationOwnershipTests: XCTestCase {
    private enum SearchInvalidation: CaseIterable {
        case clear, query, generation, queryDuringRefresh
    }

    func testSearchInvalidationPreservesUnappliedFindNavigation() async throws {
        for event in SearchInvalidation.allCases {
            let appState = makeAppState()
            defer { appState.editorFindHost.controller.cancelInFlightWork() }
            let find = try await publishFind(in: appState)
            let generation = appState.editorNavigationGeneration
            invalidateSearch(event, in: appState)
            XCTAssertEqual(appState.editorNavigationCommand, find, "\(event)")
            XCTAssertEqual(appState.editorNavigationGeneration, generation, "\(event)")
            XCTAssertEqual(appState.editorFindHost.controller.pendingNavigationCommand, find)
        }
    }

    func testSearchInvalidationStillCancelsItsOwnUnappliedNavigation() throws {
        for event in SearchInvalidation.allCases {
            let appState = makeAppState()
            try appState.issueWorkspaceSearchEditorNavigation(
                documentIdentity: XCTUnwrap(appState.activeEditorDocumentIdentity),
                selection: NSRange(location: 7, length: 3)
            )
            let request = try XCTUnwrap(appState.editorNavigationCommand)
            invalidateSearch(event, in: appState)
            guard case let .cancel(id)? = appState.editorNavigationCommand else {
                return XCTFail("\(event) must still cancel workspace-search navigation")
            }
            XCTAssertGreaterThan(id, request.id)
        }
    }

    func testOldWorkspaceSearchOwnershipCannotCancelANewerFindPublication() async throws {
        let appState = makeAppState()
        defer { appState.editorFindHost.controller.cancelInFlightWork() }
        try appState.issueWorkspaceSearchEditorNavigation(
            documentIdentity: XCTUnwrap(appState.activeEditorDocumentIdentity),
            selection: NSRange(location: 15, length: 3)
        )
        let searchID = try XCTUnwrap(appState.editorNavigationCommand?.id)
        let find = try await publishFind(in: appState)
        XCTAssertGreaterThan(find.id, searchID)
        XCTAssertEqual(appState.editorNavigationChannel.lastWorkspaceSearchNavigationID, searchID)
        appState.clearWorkspaceSearch()
        XCTAssertEqual(appState.editorNavigationCommand, find)
    }

    func testDocumentSwitchRekeyWorkspaceCloseAndBarCloseStillCancelFind() async throws {
        for event in 0 ..< 4 {
            let appState = makeAppState()
            defer { appState.editorFindHost.controller.cancelInFlightWork() }
            let find = try await publishFind(in: appState)
            switch event {
            case 0:
                appState.setCurrentDocument(
                    DocumentSession(text: "other", url: URL(fileURLWithPath: "/tmp/other.md")),
                    synchronizingWorkspaceTree: false
                )
            case 1:
                appState.notifyEditorFindDocumentIdentityDidRekey()
            case 2:
                appState.notifyEditorFindWorkspaceDidClose()
            default:
                appState.closeEditorFindBar()
            }
            guard case let .cancel(id)? = appState.editorNavigationCommand else {
                return XCTFail("lifecycle event \(event) must cancel Find navigation")
            }
            XCTAssertGreaterThan(id, find.id)
        }
    }

    private func makeAppState() -> AppState {
        let session = DocumentSession(
            text: "prefix hit one hit two",
            url: URL(fileURLWithPath: "/tmp/find-navigation-\(UUID().uuidString).md"),
            fileKind: .markdown,
            isDirty: false
        )
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        appState.editorFindHost.controller.debounceNanoseconds = 0
        appState.editorFindHost.commandContextOverride = true
        return appState
    }

    private func publishFind(in appState: AppState) async throws -> EditorNavigationCommand {
        appState.showOrRefocusEditorFind()
        appState.handleEditorFindQueryTextChange("hit")
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if case .navigate = appState.editorNavigationCommand {
                return try XCTUnwrap(appState.editorNavigationCommand)
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Find did not publish its navigation")
        return try XCTUnwrap(appState.editorNavigationCommand)
    }

    private func invalidateSearch(_ event: SearchInvalidation, in appState: AppState) {
        switch event {
        case .clear:
            appState.clearWorkspaceSearch()
        case .query:
            appState.setWorkspaceSearchQuery(TextSearchQuery(pattern: "other"))
        case .generation:
            appState.advanceWorkspaceGeneration()
        case .queryDuringRefresh:
            // No ready capture: exercise the retained-refresh branch of query replacement.
            appState.workspaceSearchRefreshIntent = WorkspaceSearchRefreshIntent(
                query: TextSearchQuery(pattern: "old"),
                rootURL: URL(fileURLWithPath: "/tmp"),
                rootExpectation: WorkspaceItemMutationExpectation(
                    identity: WorkspaceFileSystemIdentity(device: 1, inode: 1), kind: .directory
                )
            )
            appState.setWorkspaceSearchQuery(TextSearchQuery(pattern: "new"))
        }
    }
}
