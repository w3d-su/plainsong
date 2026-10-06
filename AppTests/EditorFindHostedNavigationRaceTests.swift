import AppKit
@testable import EditorKit
import Foundation
@testable import Plainsong
import XCTest

@MainActor
extension EditorFindHostedGateTests {
    func testHostedFindNavigationSurvivesWorkspaceRefreshBeforeEditorAppliesIt() async throws {
        let source = "prefix hit one hit two"
        let fixture = try makeWorkspaceFixture(files: ["post.md": source])
        let appState = fixture.appState
        appState.setLayoutMode(.sourceOnly)
        appState.openExternalFile(fixture.root)
        try await waitUntil("workspace document opens") {
            appState.currentDocument.fileURL?.lastPathComponent == "post.md"
                && appState.isWorkspaceSearchReady
        }
        appState.workspaceWatcher?.stop()
        let group = makeHostedWorkspaceGroup(fixture: fixture)
        // No editor is mounted yet: publication cannot accidentally apply before refresh.
        openFindBar(appState, query: "hit")
        try await waitUntil("Find publishes its navigation before mounting") {
            if case .navigate = appState.editorNavigationCommand { return true }
            return false
        }
        let command = try XCTUnwrap(appState.editorNavigationCommand)
        let generation = appState.editorFindHost.controller.queryGeneration
        let match = try XCTUnwrap(appState.editorFindHost.controller.session?.currentMatch?.range)

        // The same entry point the filesystem watcher uses; source and document stay intact.
        appState.refreshWorkspaceAfterFileSystemChange()
        XCTAssertEqual(appState.editorNavigationCommand, command, hostedFindTimeoutState(appState))
        let window = mountDesignatedKeyWorkspace(in: group, appState: appState)
        designateKeyWindow(window, in: group)
        try await waitUntil("the original Find match applies without another Find action") {
            self.appliedRange(in: window) == match
                && appState.workspaceInstalledCaptureGeneration == appState.workspaceGeneration
        }
        let editor = try XCTUnwrap(editorTextView(in: window))
        XCTAssertEqual(appState.currentDocument.text, source)
        XCTAssertEqual(appState.currentDocument.version, 0)
        XCTAssertEqual(appState.editorFindHost.controller.queryGeneration, generation)
        XCTAssertEqual(appState.editorNavigationCommand, command)
        XCTAssertFalse(editor.undoManager?.canUndo == true)
    }
}
