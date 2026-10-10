import AppKit
@testable import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import XCTest

/// R8 App-state contracts for the replacement row: the collapse seam, menu eligibility, and
/// the `docs/editor-replace-gates.md` §5.1 lifecycle rows that need no hosted window.
@MainActor
final class EditorReplaceUIStateTests: XCTestCase {
    private func makeAppState(text: String = "hit one hit two") -> AppState {
        let url = URL(fileURLWithPath: "/tmp/plainsong-replace-ui-\(UUID().uuidString).md")
        let session = DocumentSession(text: text, url: url, fileKind: .markdown)
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        appState.editorFindHost.controller.debounceNanoseconds = 0
        appState.editorFindHost.commandContextOverride = true
        return appState
    }

    private func openExpandedRow(_ appState: AppState, query: String = "hit", replacement: String = "NEW") {
        appState.showOrRefocusEditorFindAndReplace()
        appState.handleEditorFindQueryTextChange(query)
        appState.handleEditorReplaceTextChange(replacement)
    }

    func testCollapseAndExpandAreTheAuthoritySeamAndCollapseKeepsTheValue() {
        let appState = makeAppState()
        openExpandedRow(appState)
        appState.markEditorFindFocusApplied(appState.editorFindHost.ui.focusRequestID)
        XCTAssertTrue(appState.editorFindHost.ui.isReplaceRowActive)
        XCTAssertTrue(appState.isEditorReplaceMenuCommandEligible())
        XCTAssertTrue(MenuBarSnapshot(appState: appState).canReplace)

        let generation = appState.editorReplaceAuthorityGeneration
        appState.setEditorReplaceExpanded(false)
        XCTAssertGreaterThan(appState.editorReplaceAuthorityGeneration, generation, "collapse supersedes every plan")
        XCTAssertFalse(appState.isEditorReplaceMenuCommandEligible())
        XCTAssertFalse(MenuBarSnapshot(appState: appState).canReplace)
        XCTAssertNil(appState.performEditorReplaceMenuCommand())
        XCTAssertFalse(appState.performEditorReplaceAllMenuCommand())
        XCTAssertEqual(
            appState.performEditorReplace(replacement: "NEW"),
            .ineligible(.replaceRowCollapsed),
            "the collapsed row is structural at the plan, not only at the menu and bar"
        )
        XCTAssertNil(appState.replaceFromEditorReplaceBar(in: nil), "hidden retained text cannot execute")
        XCTAssertFalse(appState.replaceAllFromEditorReplaceBar(in: nil))
        XCTAssertEqual(appState.editorFindHost.ui.replacementText, "NEW")
        XCTAssertTrue(appState.editorFindHost.ui.isBarVisible, "collapse keeps the bar and query")

        let collapsed = appState.editorReplaceAuthorityGeneration
        appState.setEditorReplaceExpanded(false)
        XCTAssertEqual(appState.editorReplaceAuthorityGeneration, collapsed, "no transition, no advance")
        appState.setEditorReplaceExpanded(true)
        XCTAssertGreaterThan(appState.editorReplaceAuthorityGeneration, collapsed)
    }

    func testReplacementValueEditsBumpOnlyTheReplacementSeamAndValidateOnce() {
        let appState = makeAppState()
        openExpandedRow(appState, replacement: "")
        XCTAssertEqual(appState.editorFindHost.ui.replacementValidity, .valid, "empty is valid")
        XCTAssertTrue(appState.isEditorReplaceMenuCommandEligible())
        let replacementGeneration = appState.editorFindHost.replaceBatch.replacementGeneration
        appState.handleEditorReplaceTextChange(String(repeating: "a", count: 257))
        XCTAssertEqual(appState.editorFindHost.ui.replacementValidity, .exceedsMaximumUTF16Length)
        XCTAssertGreaterThan(appState.editorFindHost.replaceBatch.replacementGeneration, replacementGeneration)
        XCTAssertFalse(appState.isEditorReplaceMenuCommandEligible(), "an invalid value disables both actions")
        XCTAssertFalse(MenuBarSnapshot(appState: appState).canReplace)
        XCTAssertNil(appState.replaceFromEditorReplaceBar(in: nil))
        XCTAssertFalse(appState.replaceAllFromEditorReplaceBar(in: nil))

        // A literal-identical edit (by UTF-16 units) changes nothing.
        let unchanged = appState.editorReplaceAuthorityGeneration
        appState.handleEditorReplaceTextChange(String(repeating: "a", count: 257))
        XCTAssertEqual(appState.editorReplaceAuthorityGeneration, unchanged)
        // Precomposed vs. decomposed spelling is a real value change.
        appState.handleEditorReplaceTextChange("\u{00E9}")
        let precomposed = appState.editorFindHost.replaceBatch.replacementGeneration
        appState.handleEditorReplaceTextChange("e\u{0301}")
        XCTAssertGreaterThan(appState.editorFindHost.replaceBatch.replacementGeneration, precomposed)
        XCTAssertEqual(appState.editorFindHost.ui.replacementText.unicodeScalars.count, 2)
    }

    func testEscapeDoneKeepsQueryReplacementAndExpansionButClearsTheRowMessage() {
        let appState = makeAppState()
        openExpandedRow(appState)
        appState.editorFindHost.replaceStatus = EditorReplaceStatus(kind: .result, text: "No changes")
        let serial = appState.editorFindHost.replaceStatusSerial
        appState.closeEditorFindBar()
        XCTAssertFalse(appState.editorFindHost.ui.isBarVisible)
        XCTAssertEqual(appState.editorFindHost.ui.queryText, "hit")
        XCTAssertEqual(appState.editorFindHost.ui.replacementText, "NEW")
        XCTAssertTrue(appState.editorFindHost.ui.isReplaceExpanded)
        XCTAssertNil(appState.editorFindHost.replaceStatus)
        XCTAssertGreaterThan(appState.editorFindHost.replaceStatusSerial, serial, "a late result cannot land")
        XCTAssertFalse(appState.isEditorReplaceMenuCommandEligible())
    }

    func testNoDocumentClosesAndCollapsesKeepsValuesAndNeverResetsReceiptHighWaterMarks() {
        let appState = makeAppState()
        openExpandedRow(appState)
        appState.setEditorFindChromeFocus(.next, inWindowNumber: 41)
        appState.showOrRefocusEditorFind()
        let pending = appState.editorFindHost.ui
        XCTAssertGreaterThan(pending.focusRequestID, pending.focusAppliedID)

        appState.currentDocument = DocumentSession()
        appState.notifyEditorFindDocumentDidSwitch()

        let ui = appState.editorFindHost.ui
        XCTAssertFalse(ui.isBarVisible)
        XCTAssertFalse(ui.isReplaceExpanded, "no document collapses the row")
        XCTAssertEqual(ui.queryText, "hit", "workspace UI memory")
        XCTAssertEqual(ui.replacementText, "NEW", "workspace UI memory")
        XCTAssertNil(appState.editorFindHost.controller.session)
        XCTAssertTrue(appState.editorFindHost.chromeFocusByWindow.isEmpty)
        XCTAssertEqual(ui.focusRequestID, pending.focusRequestID, "high-water marks are never reset")
        XCTAssertEqual(ui.selectAllRequestID, pending.selectAllRequestID)
        XCTAssertEqual(ui.focusSupersededID, pending.focusRequestID, "the pending focus is superseded")
        XCTAssertFalse(MenuBarSnapshot(appState: appState).canReplace)
    }

    func testWorkspaceCloseClearsBothValuesCollapsesAndKeepsReceiptHighWaterMarks() {
        let appState = makeAppState()
        openExpandedRow(appState)
        appState.setEditorFindChromeFocus(.matchCase, inWindowNumber: 42)
        let before = appState.editorFindHost.ui
        let generation = appState.editorReplaceAuthorityGeneration

        appState.notifyEditorFindWorkspaceDidClose()

        let ui = appState.editorFindHost.ui
        XCTAssertFalse(ui.isBarVisible)
        XCTAssertFalse(ui.isReplaceExpanded)
        XCTAssertEqual(ui.queryText, "")
        XCTAssertEqual(ui.replacementText, "")
        XCTAssertEqual(ui.replacementValidity, .valid)
        XCTAssertEqual(appState.editorFindHost.replaceBatch.replacement, "", "no retained value can execute later")
        XCTAssertGreaterThan(appState.editorReplaceAuthorityGeneration, generation)
        XCTAssertTrue(appState.editorFindHost.chromeFocusByWindow.isEmpty)
        XCTAssertEqual(ui.focusRequestID, before.focusRequestID)
        XCTAssertEqual(ui.focusAppliedID, before.focusAppliedID)
        XCTAssertEqual(ui.selectAllRequestID, before.selectAllRequestID)
        XCTAssertGreaterThanOrEqual(ui.focusSupersededID, ui.focusRequestID, "a remount cannot replay a token")
    }

    func testReloadOrKeepMineCompletionClearsABlockedMessageButKeepsTheRow() {
        let appState = makeAppState()
        openExpandedRow(appState)
        appState.editorFindHost.replaceStatus = EditorReplaceStatusText.blocked(.externalChangeAwaitingChoice)
        let generation = appState.editorReplaceAuthorityGeneration
        appState.editorReplaceExternalResolutionDidComplete(for: appState.currentDocument)
        XCTAssertNil(appState.editorFindHost.replaceStatus)
        XCTAssertGreaterThan(appState.editorReplaceAuthorityGeneration, generation)
        XCTAssertTrue(appState.editorFindHost.ui.isReplaceRowActive)
        XCTAssertEqual(appState.editorFindHost.ui.replacementText, "NEW")
        XCTAssertEqual(appState.editorFindHost.ui.queryText, "hit")
    }
}
