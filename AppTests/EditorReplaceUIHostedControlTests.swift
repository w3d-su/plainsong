import AppKit
@testable import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import WorkspaceKit
import XCTest

/// R8 on the real replacement row: identifiers, the owned field and its validation, the
/// bar's buttons, Return, and every spoken non-color-only state. Controls are clicked through
/// AppKit (`performClick`) and the field through its real field editor.
@MainActor
extension EditorFindHostedGateTests {
    func testHostedReplaceRowKeepsFindRowIdentifiersAndOwnsEveryReplaceIdentifier() async throws {
        // Find row identifiers are unchanged (F-gate and XCUITest compatibility).
        XCTAssertEqual(
            [EditorFindAccessibility.bar, EditorFindAccessibility.queryField, EditorFindAccessibility.matchCase,
             EditorFindAccessibility.wholeWord, EditorFindAccessibility.matchCounter,
             EditorFindAccessibility.truncatedIndicator, EditorFindAccessibility.nextButton,
             EditorFindAccessibility.previousButton, EditorFindAccessibility.doneButton],
            ["plainsong.editorFind.bar", "plainsong.editorFind.queryField", "plainsong.editorFind.matchCase",
             "plainsong.editorFind.wholeWord", "plainsong.editorFind.matchCounter",
             "plainsong.editorFind.truncated", "plainsong.editorFind.next",
             "plainsong.editorFind.previous", "plainsong.editorFind.done"]
        )
        let replaceIDs = [
            EditorFindAccessibility.replaceDisclosure, EditorFindAccessibility.replacementField,
            EditorFindAccessibility.replaceButton, EditorFindAccessibility.replaceAllButton,
            EditorFindAccessibility.replaceProgress, EditorFindAccessibility.replaceCancelButton,
            EditorFindAccessibility.replaceBlockedReason, EditorFindAccessibility.replaceOverflow,
            EditorFindAccessibility.replaceStatus, EditorFindAccessibility.replacementFieldError,
        ]
        XCTAssertTrue(replaceIDs.allSatisfy { $0.hasPrefix("plainsong.editorFind.") })
        XCTAssertEqual(Set(replaceIDs).count, replaceIDs.count)

        let fixture = try makeWorkspaceFixture(files: ["post.md": "hit one"])
        let app = fixture.appState
        app.setLayoutMode(.sourceOnly)
        app.openExternalFile(fixture.root)
        try await waitUntil("workspace document opens") { app.hasOpenDocument }
        let group = makeHostedWorkspaceGroup(fixture: fixture)
        let window = mountDesignatedKeyWorkspace(in: group, appState: app)
        designateKeyWindow(window, in: group)
        openFindBar(app, query: "hit")
        let query = try await waitForFindQueryField(in: window)
        XCTAssertEqual(query.accessibilityIdentifier(), EditorFindAccessibility.queryField)

        // Collapsed: only the disclosure belongs to Replace; no hidden replacement control.
        let disclosure = try await waitForBarButton(EditorFindAccessibility.replaceDisclosure, in: window)
        XCTAssertEqual(disclosure.state, .off)
        XCTAssertEqual(disclosure.accessibilityLabel(), "Show Replace")
        XCTAssertNil(replacementField(in: window))
        XCTAssertNil(barButton(EditorFindAccessibility.replaceButton, in: window))

        disclosure.performClick(nil)
        let field = try await waitForReplacementField(in: window)
        XCTAssertEqual(field.accessibilityLabel(), EditorFindAccessibility.replacementFieldLabel)
        XCTAssertEqual(field.placeholderString, EditorFindAccessibility.replacementFieldPlaceholder)
        try await waitUntil("disclosure reports the expanded row") {
            disclosure.state == .on && disclosure.accessibilityLabel() == "Hide Replace"
        }
        let replace = try await waitForBarButton(EditorFindAccessibility.replaceButton, in: window)
        let replaceAll = try await waitForBarButton(EditorFindAccessibility.replaceAllButton, in: window)
        XCTAssertEqual(replace.title, "Replace")
        XCTAssertEqual(replaceAll.title, "Replace All")
        try await waitUntil("with an active query, an empty replacement is valid") {
            app.editorFindHost.ui.hasActiveQuery && replace.isEnabled && replaceAll.isEnabled
        }
        XCTAssertNil(barButton(EditorFindAccessibility.replaceCancelButton, in: window), "Cancel only while preparing")
        XCTAssertTrue(findQueryField(in: window) === query, "expanding never remounts the query field")
    }

    func testHostedReplacementOverLimitShowsFieldErrorAndDisablesBothActionsWhileEmptyStaysValid() async throws {
        let hosted = try await makeHostedReplaceRow(replacement: nil)
        let app = hosted.appState
        let window = hosted.window
        let editor = try hostedEditor(hosted)
        let replace = try await waitForBarButton(EditorFindAccessibility.replaceButton, in: window)
        let replaceAll = try await waitForBarButton(EditorFindAccessibility.replaceAllButton, in: window)

        // 129 surrogate pairs: 258 UTF-16 code units in only 129 characters.
        try typeReplacement(String(repeating: "🦊", count: 129), in: window)
        try await waitUntil("the over-limit error is shown and both actions disable") {
            self.label(EditorFindAccessibility.replacementFieldError, in: window)?.stringValue
                == "Replacement is too long: the limit is 256 text units, and most emoji count as 2"
                && !replace.isEnabled && !replaceAll.isEnabled
        }
        let tooLong = "Replacement is too long: the limit is 256 text units, and most emoji count as 2"
        XCTAssertEqual(replacementField(in: window)?.accessibilityHelp(), tooLong, "the error is tied to the field")
        XCTAssertEqual(app.editorFindHost.lastReplaceAnnouncement, tooLong, "and spoken when it appears")
        let before = EditorReplaceEffectSnapshot(app, textView: editor)
        XCTAssertFalse(EditorFindCommandDelivery.performReplace())
        XCTAssertFalse(EditorFindCommandDelivery.performReplaceAll())
        XCTAssertFalse(MenuBarSnapshot(appState: app).canReplace)
        XCTAssertNil(app.replaceFromEditorReplaceBar(in: window))
        XCTAssertNil(app.editorFindHost.replaceAllTask)
        XCTAssertEqual(EditorReplaceEffectSnapshot(app, textView: editor), before)

        try typeReplacement("a\nb", in: window)
        try await waitUntil("a literal line break is rejected, not converted") {
            self.label(EditorFindAccessibility.replacementFieldError, in: window)?.stringValue
                == "Replacement must be a single line" && !replace.isEnabled
        }
        XCTAssertEqual(app.editorFindHost.ui.replacementText, "a\nb")

        try typeReplacement(
            String(repeating: "x", count: EditorReplaceLimits.maximumReplacementUTF16Length),
            in: window
        )
        try await waitUntil("exactly 256 units is valid") {
            self.label(EditorFindAccessibility.replacementFieldError, in: window) == nil && replace.isEnabled
        }

        // Empty deletes the match.
        try typeReplacement("", in: window)
        try await waitUntil("empty replacement keeps both actions enabled") {
            replace.isEnabled && replaceAll.isEnabled && app.editorFindHost.ui.replacementText.isEmpty
        }
        replace.performClick(nil)
        XCTAssertEqual(app.currentDocument.text, " one hit two")
        XCTAssertTrue(MenuBarSnapshot(appState: app).canReplace)
    }

    func testHostedReplaceButtonAndReturnReplaceThroughRealControlsAndKeepFieldFocus() async throws {
        let hosted = try await makeHostedReplaceRow(source: "hit one hit two hit", replacement: "$1\\n")
        let app = hosted.appState
        let window = hosted.window
        XCTAssertTrue(isReplacementFieldFirstResponder(in: window))

        try await click(EditorFindAccessibility.replaceButton, in: window)
        XCTAssertEqual(app.currentDocument.text, "$1\\n one hit two hit", "literal: no escape expansion")
        try await waitUntil("post-write rescan advances to the next retained match") {
            app.editorFindHost.controller.session?.currentOrdinal == 1
                && app.editorFindHost.controller.session?.total == 2
        }

        // Return in the replacement field is the same explicit Replace.
        let fieldEditor = try replacementFieldEditor(in: window)
        try await waitUntil("the advanced match is applied in the editor") {
            self.appliedRange(in: window) == app.editorFindHost.controller.session?.currentMatch?.range
        }
        fieldEditor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(app.currentDocument.text, "$1\\n one $1\\n two hit")
        XCTAssertTrue(isReplacementFieldFirstResponder(in: window), "Replace never takes focus from the field")
        XCTAssertEqual(app.editorFindHost.ui.replacementText, "$1\\n", "Return never edits the value")
        let editor = try hostedEditor(hosted)
        editor.undoManager?.undo()
        XCTAssertEqual(app.currentDocument.text, "$1\\n one hit two hit", "each Replace is one undo step")
    }

    func testHostedReplaceAllButtonSpeaksChangedOfTotalAndNoChanges() async throws {
        let hosted = try await makeHostedReplaceRow(source: "hit HIT hit", replacement: "HIT")
        let app = hosted.appState
        let window = hosted.window
        try await click(EditorFindAccessibility.replaceAllButton, in: window)
        await awaitBarReplaceAll(app)
        XCTAssertEqual(app.currentDocument.text, "HIT HIT HIT")
        XCTAssertEqual(
            app.editorFindHost.replaceStatus,
            EditorReplaceStatus(kind: .result, text: "Changed 2 of 3 matches")
        )
        XCTAssertEqual(app.editorFindHost.lastReplaceAnnouncement, "Changed 2 of 3 matches")
        try await waitUntil("the result label shows the spoken text") {
            self.label(EditorFindAccessibility.replaceStatus, in: window)?.stringValue == "Changed 2 of 3 matches"
        }
        XCTAssertEqual(
            label(EditorFindAccessibility.replaceStatus, in: window)?.accessibilityValue() as? String,
            "Changed 2 of 3 matches"
        )

        try await waitUntil("the post-write rescan has a fresh retained set") {
            app.editorFindHost.controller.session?.total == 3
        }
        try await click(EditorFindAccessibility.replaceAllButton, in: window)
        await awaitBarReplaceAll(app)
        XCTAssertEqual(app.currentDocument.text, "HIT HIT HIT")
        XCTAssertEqual(app.editorFindHost.lastReplaceAnnouncement, "No changes")
        try await waitUntil("No changes is shown as text") {
            self.label(EditorFindAccessibility.replaceStatus, in: window)?.stringValue == "No changes"
        }
    }

    func testHostedOverflowAndBlockedStatesAreSpokenTextAndRefuseWithZeroEffect() async throws {
        let source = String(repeating: "x ", count: EditorFindLimits.retainedMatchCeiling + 1)
        let hosted = try await makeHostedReplaceRow(source: source, query: "x")
        let app = hosted.appState
        let window = hosted.window
        let editor = try hostedEditor(hosted)
        try await waitUntil("the overflow state is shown before any action") {
            self.label(EditorFindAccessibility.replaceOverflow, in: window)?.stringValue
                == "More than 10,000 matches; narrow the search."
        }
        var before = EditorReplaceEffectSnapshot(app, textView: editor)
        try await click(EditorFindAccessibility.replaceAllButton, in: window)
        await awaitBarReplaceAll(app)
        XCTAssertEqual(app.editorFindHost.replaceStatus?.kind, .overflow)
        XCTAssertEqual(app.editorFindHost.lastReplaceAnnouncement, "More than 10,000 matches; narrow the search.")
        XCTAssertEqual(EditorReplaceEffectSnapshot(app, textView: editor).appText, before.appText)
        XCTAssertFalse(editor.undoManager?.canUndo == true)

        // The transient inspection window after every autosave is a momentary blocked state.
        let session = app.currentDocument
        let location = try WorkspaceFileSystemLocation(fileURL: hosted.postURL)
        app.externalDiskInspectionTasks[ObjectIdentifier(session)] = ExternalDiskInspectionTask(
            token: UUID(), session: session, canonicalURL: location.fileURL, location: location,
            lifecycleGeneration: 0, diskEventGeneration: 0,
            sourceSnapshot: EditorDocumentSourceSnapshot(source: session.text, revision: session.version),
            task: Task {}
        )
        before = EditorReplaceEffectSnapshot(app, textView: editor)
        try await click(EditorFindAccessibility.replaceButton, in: window)
        let transient = "Checking the file for outside changes; try again in a moment"
        XCTAssertEqual(
            app.editorFindHost.replaceStatus,
            EditorReplaceStatus(
                kind: .blocked, text: transient, blockedReason: .externalObservationPending
            )
        )
        XCTAssertEqual(app.editorFindHost.lastReplaceAnnouncement, transient)
        try await waitUntil("the blocked reason is shown as text") {
            self.label(EditorFindAccessibility.replaceBlockedReason, in: window)?.stringValue == transient
        }
        XCTAssertEqual(EditorReplaceEffectSnapshot(app, textView: editor).appText, before.appText)
        XCTAssertEqual(EditorReplaceEffectSnapshot(app, textView: editor).selection, before.selection)

        // Once the inspection settles, a fresh explicit action proceeds; nothing was queued.
        app.externalDiskInspectionTasks[ObjectIdentifier(session)] = nil
        XCTAssertEqual(app.currentDocument.text, before.appText)
        try await click(EditorFindAccessibility.replaceButton, in: window)
        XCTAssertNotEqual(app.currentDocument.text, before.appText)
        XCTAssertEqual(app.editorFindHost.replaceStatus, EditorReplaceStatus(kind: .result, text: "Replaced 1 match"))
        XCTAssertEqual(app.editorFindHost.lastReplaceAnnouncement, "Replaced 1 match")
    }

    /// An owned AppKit status label in `window`.
    func label(_ identifier: String, in window: NSWindow) -> NSTextField? {
        firstDescendant(of: NSTextField.self, in: window.contentView) {
            $0.accessibilityIdentifier() == identifier && !$0.isEditable
        }
    }
}
