@testable import MarkdownCore
@testable import Plainsong
import XCTest

@MainActor
extension EditorFindHostedGateTests {
    /// Picking a file whose session is already warm must hand the dirty document's pending
    /// autosave to the per-session tasks, as a cold pick does. The session owns its count,
    /// which keeps running when the document leaves the window.
    func testSwitchingToACachedFileKeepsThePreviousDocumentsAutosaveAndStatistics() async throws {
        let fixture = try await makeReadyFilesSwitchFixture()
        let state = fixture.appState
        let sessionA = state.shownSession
        let aID = try XCTUnwrap(state.workspaceTree?.root.children.first { $0.name == "a.md" }?.id)
        let bID = try XCTUnwrap(state.workspaceTree?.root.children.first { $0.name == "b.md" }?.id)
        XCTAssertTrue(state.selectWorkspaceNode(id: bID, requestingEditorFocus: false))
        XCTAssertTrue(state.selectWorkspaceNode(id: aID, requestingEditorFocus: false))
        XCTAssertTrue(state.shownSession === sessionA)

        state.replaceDocumentText("alpha unsaved", in: sessionA)
        XCTAssertNotNil(state.autosaveTask)
        XCTAssertNotNil(sessionA.statisticsTask)

        XCTAssertTrue(state.selectWorkspaceNode(id: bID, requestingEditorFocus: false))

        XCTAssertFalse(state.shownSession === sessionA)
        XCTAssertTrue(sessionA.isDirty)
        XCTAssertNotNil(state.sessionAutosaveTasks[ObjectIdentifier(sessionA)])
        XCTAssertNotNil(sessionA.statisticsTask)
    }
}
