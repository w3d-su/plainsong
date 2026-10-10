import AppKit
@testable import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import XCTest

/// R8 menus: Edit ▸ Find and Replace… / Replace / Replace All through the production
/// dispatchers (`EditorFindCommandDelivery`, exactly what the menu items call), with the
/// production key-window responder eligibility — no command-context override.
@MainActor
extension EditorFindHostedGateTests {
    func testEditMenuAddsFindAndReplaceReplaceAndReplaceAllWithoutShortcuts() async throws {
        // The hosted app builds its real SwiftUI command menu on the main run loop.
        for _ in 0 ..< 100 {
            if NSApp.mainMenu?.items.first(where: { $0.title == "Edit" })?.submenu?
                .items.contains(where: { $0.title == "Replace All" }) == true { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let edit = try XCTUnwrap(NSApp.mainMenu?.items.first(where: { $0.title == "Edit" })?.submenu)
        let titles = edit.items.map(\.title)
        for title in ["Find and Replace…", "Replace", "Replace All"] {
            XCTAssertEqual(titles.filter { $0 == title }.count, 1, "\(title) appears once: \(titles)")
            let item = try XCTUnwrap(edit.items.first { $0.title == title })
            XCTAssertEqual(item.keyEquivalent, "", "\(title) has no global shortcut")
        }
        let find = try XCTUnwrap(titles.firstIndex(of: "Find…"))
        XCTAssertEqual(titles.firstIndex(of: "Find and Replace…"), find + 1)
        XCTAssertLessThan(
            try XCTUnwrap(titles.firstIndex(of: "Use Selection for Find")),
            try XCTUnwrap(titles.firstIndex(of: "Replace"))
        )
        let format = try XCTUnwrap(NSApp.mainMenu?.items.first(where: { $0.title == "Format" })?.submenu)
        let table = try XCTUnwrap(format.items.first { $0.title == "Format Table" })
        XCTAssertEqual(table.keyEquivalent, "f")
        XCTAssertEqual(table.keyEquivalentModifierMask, [.option, .command], "⌥⌘F stays Format Table")
    }

    func testHostedReplaceMenuEligibilityMatrixReachesOnlyTheExpandedKeyWindowRow() async throws {
        let hosted = try await makeHostedReplaceRow(source: "hit one hit two hit three")
        let app = hosted.appState
        let window = hosted.window
        let editor = try hostedEditor(hosted)

        // Bar hidden: retained value and expansion cannot execute.
        app.closeEditorFindBar()
        XCTAssertTrue(app.editorFindHost.ui.isReplaceExpanded)
        XCTAssertEqual(app.editorFindHost.ui.replacementText, "NEW")
        var before = EditorReplaceEffectSnapshot(app, textView: editor)
        XCTAssertFalse(EditorFindCommandDelivery.performReplace())
        XCTAssertFalse(EditorFindCommandDelivery.performReplaceAll())
        XCTAssertFalse(MenuBarSnapshot(appState: app).canReplace)
        XCTAssertNil(app.editorFindHost.replaceAllTask)
        XCTAssertEqual(EditorReplaceEffectSnapshot(app, textView: editor), before)

        // Visible but collapsed through the real disclosure: still ineligible.
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertTrue(EditorFindCommandDelivery.performShowFind())
        try await waitUntil("⌘F reopens the bar with the row still expanded") {
            self.replacementField(in: window) != nil && self.isFindFieldFirstResponder(in: window)
        }
        try await click(EditorFindAccessibility.replaceDisclosure, in: window)
        XCTAssertFalse(app.editorFindHost.ui.isReplaceExpanded)
        try await waitUntil("collapse unmounts the replacement field") { self.replacementField(in: window) == nil }
        before = EditorReplaceEffectSnapshot(app, textView: editor)
        XCTAssertTrue(app.isEditorFindCommandContextActive(), "the query field is real key-window provenance")
        XCTAssertFalse(EditorFindCommandDelivery.performReplace())
        XCTAssertFalse(EditorFindCommandDelivery.performReplaceAll())
        XCTAssertFalse(MenuBarSnapshot(appState: app).canReplace)
        XCTAssertEqual(EditorReplaceEffectSnapshot(app, textView: editor), before)
        XCTAssertEqual(app.editorFindHost.ui.replacementText, "NEW", "collapse keeps the value")

        // Expanded, query field focused: eligible; the first action only navigates.
        try await click(EditorFindAccessibility.replaceDisclosure, in: window)
        _ = try await waitForReplacementField(in: window)
        try await waitUntil("Find applies the current match") {
            self.appliedRange(in: window) == app.editorFindHost.controller.session?.currentMatch?.range
        }
        try clickIntoFindField(in: window)
        XCTAssertTrue(MenuBarSnapshot(appState: app).canReplace)
        XCTAssertTrue(EditorFindCommandDelivery.performReplace())
        XCTAssertEqual(app.currentDocument.text, "NEW one hit two hit three")
        XCTAssertTrue(isFindFieldFirstResponder(in: window), "the menu action leaves focus in the query field")

        // Replacement field focused: eligible.
        try await waitUntil("the next match is applied") {
            self.appliedRange(in: window) == app.editorFindHost.controller.session?.currentMatch?.range
        }
        _ = try replacementFieldEditor(in: window)
        XCTAssertTrue(app.isEditorReplaceMenuCommandEligible())
        XCTAssertTrue(EditorFindCommandDelivery.performReplace())
        XCTAssertEqual(app.currentDocument.text, "NEW one NEW two hit three")

        // Focus outside the editor and both fields: ineligible even with the row expanded.
        XCTAssertTrue(window.makeFirstResponder(nil))
        before = EditorReplaceEffectSnapshot(app, textView: editor)
        XCTAssertFalse(EditorFindCommandDelivery.performReplace())
        XCTAssertFalse(EditorFindCommandDelivery.performReplaceAll())
        XCTAssertEqual(EditorReplaceEffectSnapshot(app, textView: editor), before)

        // Replace All from the replacement field.
        try await waitUntil("the post-write rescan retains the last match") {
            app.editorFindHost.controller.session?.total == 1
        }
        _ = try replacementFieldEditor(in: window)
        XCTAssertTrue(EditorFindCommandDelivery.performReplaceAll())
        await awaitBarReplaceAll(app)
        XCTAssertEqual(app.currentDocument.text, "NEW one NEW two NEW three")
        XCTAssertEqual(app.editorFindHost.lastReplaceAnnouncement, "Changed 1 of 1 matches")
    }

    func testHostedReplaceMenuFromABackgroundWindowCannotReachAnotherWindowsRow() async throws {
        let hosted = try await makeHostedReplaceRow(source: "hit one hit two")
        let app = hosted.appState
        let windowA = hosted.window
        let windowB = mountDesignatedKeyWorkspace(in: hosted.group, appState: app, originX: 40)
        _ = try await waitForReplacementField(in: windowB)
        let editorA = try hostedEditor(hosted)
        // A keeps its replacement field focused but is no longer key; B is key with no
        // editor or bar focus.
        _ = try replacementFieldEditor(in: windowA)
        designateKeyWindow(windowB, in: hosted.group)
        XCTAssertTrue(windowB.makeFirstResponder(nil))
        let before = EditorReplaceEffectSnapshot(app, textView: editorA)
        XCTAssertFalse(app.isEditorFindCommandContextActive())
        XCTAssertFalse(EditorFindCommandDelivery.performReplace())
        XCTAssertFalse(EditorFindCommandDelivery.performReplaceAll())
        XCTAssertFalse(EditorFindCommandDelivery.performShowFindAndReplace())
        XCTAssertEqual(EditorReplaceEffectSnapshot(app, textView: editorA), before)
        XCTAssertNil(app.editorFindHost.replaceAllTask)

        // Back to A: its own field is provenance again and only A's editor is reached.
        designateKeyWindow(windowA, in: hosted.group)
        XCTAssertTrue(app.isEditorReplaceMenuCommandEligible())
        XCTAssertTrue(EditorFindCommandDelivery.performReplace())
        XCTAssertEqual(app.currentDocument.text, "NEW one hit two")
        XCTAssertEqual(editorA.undoManager?.canUndo, true, "the replacement is A's native undo step")
    }

    func testHostedRemountedBarCannotReplayAFocusTokenOrAPreparingPlan() async throws {
        let hosted = try await makeHostedReplaceRow(source: String(repeating: "hit ", count: 200))
        let app = hosted.appState
        let windowA = hosted.window
        let editor = try hostedEditor(hosted)
        XCTAssertTrue(windowA.makeFirstResponder(editor))
        XCTAssertTrue(EditorFindCommandDelivery.performShowFindAndReplace())
        let request = app.editorFindHost.ui.focusRequestID
        try await waitUntil("Find and Replace… spends its query receipt in A") {
            app.editorFindHost.ui.focusAppliedID == request && self.isFindFieldFirstResponder(in: windowA)
        }
        _ = try replacementFieldEditor(in: windowA)
        let hold = try await startHeldBarReplaceAll(hosted) {
            XCTAssertTrue(EditorFindCommandDelivery.performReplaceAll())
        }
        let before = EditorReplaceEffectSnapshot(app, textView: editor)

        // A new window mounts a fresh bar (both owned fields) on the shared App state.
        let windowC = mountDesignatedKeyWorkspace(in: hosted.group, appState: app, originX: 80)
        _ = try await waitForReplacementField(in: windowC)
        designateKeyWindow(windowC, in: hosted.group)
        XCTAssertFalse(app.editorFindHost.replaceBatch.isPreparing, "a remounted owner supersedes the plan")
        hold.release()
        await awaitBarReplaceAll(app)
        XCTAssertEqual(app.editorFindHost.replaceBatch.lastResult, .superseded)
        XCTAssertEqual(app.currentDocument.text, before.appText)
        XCTAssertEqual(editor.undoManager?.canUndo, before.canUndo)
        try await assertFocusRemains(
            "the remounted bar never replays the spent query token",
            windows: [windowA, windowC],
            appState: app
        ) {
            !self.isFindFieldFirstResponder(in: windowC) && !self.isReplacementFieldFirstResponder(in: windowC)
                && app.editorFindHost.ui.focusRequestID == request
                && app.editorFindHost.ui.focusAppliedID == request
        }
        // C's mounted editor may legitimately take first responder; with focus elsewhere
        // in C nothing is eligible, and nothing was replayed by the mount itself.
        XCTAssertTrue(windowC.makeFirstResponder(nil))
        XCTAssertFalse(EditorFindCommandDelivery.performReplace(), "C has no bar or editor focus")
        XCTAssertFalse(EditorFindCommandDelivery.performReplaceAll())
        XCTAssertEqual(app.currentDocument.text, before.appText)
    }
}
