import AppKit
@testable import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import XCTest

/// Hosted production-path evidence for workspace-search click → other-file selection/scroll.
///
/// The existing keyboard smoke observes only `editorNavigationCommand` after a real row click.
/// The XCUITest observes native selection after Return. This gate drives a real `NSEvent` click
/// on a result in a different file inside the production `WorkspaceWindow` and asserts the
/// installed native UTF-16 selection plus visible-range containment.
@MainActor
final class WorkspaceSearchHostedActivationTests: XCTestCase {
    func testClickingAResultInAnotherFileSelectsTheExactUTF16MatchAndScrollsItIntoView() async throws {
        let document = makeOffscreenOtherFileDocument()
        let fixture = try makeSearchWorkspaceFixture(files: [
            "a-current.md": "alpha file without the unique token\n",
            "z-other.md": document.source,
        ])
        let appState = fixture.appState
        appState.setLayoutMode(.sourceOnly)
        appState.openExternalFile(fixture.root)
        try await waitUntil("workspace opens the current file and is search-ready") {
            appState.currentDocument.fileURL?.lastPathComponent == "a-current.md"
                && appState.isWorkspaceSearchReady
        }

        let host = makeWorkspaceHost(appState: appState, width: 1100, height: 520)
        registerTeardown(host: host, fixture: fixture)
        appState.workspaceSearchFocusKeyWindowCheck = { $0 === host.window }
        appState.selectWorkspaceSidebarMode(.search)
        appState.updateWorkspaceSearchQueryText(document.needle)

        try await waitUntil("search completes with the other-file match") {
            appState.workspaceSearchState.phase == .completed
                && !appState.workspaceSearchUI.queryText.isEmpty
                && appState.workspaceSearchState.fileResults.contains {
                    $0.relativePath == "z-other.md" && $0.matches.count == 1
                }
        }
        let otherResult = try XCTUnwrap(
            appState.workspaceSearchState.fileResults.first { $0.relativePath == "z-other.md" }
        )
        XCTAssertNotNil(otherResult.fileAuthority, "production search results must carry file authority")
        XCTAssertEqual(appState.currentDocument.fileURL?.lastPathComponent, "a-current.md")
        XCTAssertEqual(
            WorkspaceSearchSelectionNavigation.orderedRowIDs(in: resultsPresentation(appState)).count,
            1,
            "the List must render the other-file match, not the empty-query prompt"
        )

        host.hostingView.layoutSubtreeIfNeeded()
        let tableView = try await waitForResultsTable(in: host.window)
        appState.editorNavigationCommand = nil
        sendClickOnLastRow(of: tableView, to: host.window)
        try await assertClickActivated(
            document,
            in: host.window,
            appState: appState
        )
    }
}
