import AppKit
@testable import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import XCTest

/// R6 deterministic bullets 1–4 with synthetic AppKit marked text in each of the three owners
/// (`docs/editor-replace-gates.md` §5.5). Real Zhuyin/Pinyin input stays the owner harness's.
@MainActor
extension EditorFindHostedGateTests {
    enum MarkedTextOwner: CaseIterable {
        case editor
        case queryField
        case replacementField
    }

    /// Starts synthetic composition in `owner` without committing it. Returns the composing
    /// text view so the caller can end composition.
    func beginComposition(in owner: MarkedTextOwner, of hosted: HostedReplaceWorkspace) throws -> NSTextView? {
        let window = hosted.window
        switch owner {
        case .editor:
            let editor = try hostedEditor(hosted)
            editor.setMarkedText("ㄓ", selectedRange: NSRange(location: 1, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertTrue(editor.hasMarkedText())
            return nil
        case .queryField:
            let field = try XCTUnwrap(findQueryField(in: window))
            XCTAssertTrue(window.makeFirstResponder(field))
            let fieldEditor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            fieldEditor.setMarkedText("ㄅ", selectedRange: NSRange(location: 1, length: 0),
                                      replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertTrue(fieldEditor.hasMarkedText())
            return fieldEditor
        case .replacementField:
            let fieldEditor = try replacementFieldEditor(in: window)
            fieldEditor.setMarkedText("ㄆ", selectedRange: NSRange(location: 1, length: 0),
                                      replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertTrue(fieldEditor.hasMarkedText())
            return fieldEditor
        }
    }

    func endComposition(in owner: MarkedTextOwner, of hosted: HostedReplaceWorkspace, fieldEditor: NSTextView?) throws {
        switch owner {
        case .editor: try hostedEditor(hosted).unmarkText()
        case .queryField, .replacementField: fieldEditor?.unmarkText()
        }
    }

    /// Bullets 1–2: every entry point refuses while any owner composes, before navigation,
    /// reveal, authorization, undo, progress, or ordinal change; nothing is queued.
    func testHostedMarkedTextInEachOwnerRefusesReplaceAndReplaceAllWithZeroEffect() async throws {
        for owner in MarkedTextOwner.allCases {
            // The current match is deliberately *not* selected, so a non-refused single
            // Replace would navigate: refusal must come first.
            let hosted = try await makeHostedReplaceRow(source: "hit one hit two")
            let app = hosted.appState
            let editor = try hostedEditor(hosted)
            editor.textSelection = NSRange(location: 15, length: 0)
            try await waitUntil("\(owner): the caret leaves the match") {
                self.appliedRange(in: hosted.window) == NSRange(location: 15, length: 0)
            }
            app.editorFindHost.replaceAuthority.lastAuthorizationRecord = nil
            let fieldEditor = try beginComposition(in: owner, of: hosted)
            let before = EditorReplaceEffectSnapshot(app, textView: editor)
            let generation = app.editorReplaceAuthorityGeneration
            let ordinal = app.editorFindHost.controller.session?.currentOrdinal

            XCTAssertEqual(app.performEditorReplace(replacement: "NEW"), .markedText, "\(owner)")
            XCTAssertEqual(app.replaceFromEditorReplaceBar(in: hosted.window), .markedText, "\(owner): bar / Return")
            let result = await app.performEditorReplaceAll(replacement: "NEW")
            XCTAssertEqual(result, .markedText, "\(owner)")
            // The replacement or query field is first responder: menus are eligible.
            XCTAssertEqual(app.performEditorReplaceMenuCommand(), .markedText, "\(owner): menu")
            XCTAssertNil(app.editorFindHost.replaceAuthority.lastAuthorizationRecord, "\(owner): no authorization")
            XCTAssertEqual(EditorReplaceEffectSnapshot(app, textView: editor), before, "\(owner)")
            XCTAssertEqual(app.editorFindHost.controller.session?.currentOrdinal, ordinal, "\(owner)")
            XCTAssertFalse(app.editorFindHost.replaceBatch.isPreparing, "\(owner): no progress")
            XCTAssertTrue(app.editorFindHost.replaceBatch.progress.isEmpty, "\(owner)")
            XCTAssertEqual(app.editorReplaceAuthorityGeneration, generation, "\(owner): refusal changes no input")
            XCTAssertEqual(app.editorFindHost.lastReplaceAnnouncement, "Finish text input before replacing")

            // Composition ends: nothing queued fires.
            try endComposition(in: owner, of: hosted, fieldEditor: fieldEditor)
            try await assertRemains("\(owner): no queued post-composition Replace") {
                app.currentDocument.text == "hit one hit two"
                    && !app.editorFindHost.replaceBatch.isPreparing
                    && app.editorFindHost.replaceAuthority.lastAuthorizationRecord == nil
            }
            XCTAssertFalse(editor.undoManager?.canUndo == true, "\(owner)")
        }
    }

    /// Bullet 3: Return and Escape in the replacement field belong to the input context while
    /// it composes; afterwards a fresh Return is the one explicit Replace.
    func testHostedReplacementFieldReturnAndEscapeDeferToCompositionThenAFreshReturnReplacesOnce() async throws {
        let hosted = try await makeHostedReplaceRow(source: "hit one hit two")
        let app = hosted.appState
        let window = hosted.window
        let editor = try hostedEditor(hosted)
        let field = try XCTUnwrap(replacementField(in: window))
        let coordinator = try XCTUnwrap(field.delegate as? EditorReplaceField.Coordinator)
        app.editorFindHost.replaceAuthority.lastAuthorizationRecord = nil
        let fieldEditor = try XCTUnwrap(try beginComposition(in: .replacementField, of: hosted))
        let before = EditorReplaceEffectSnapshot(app, textView: editor)

        for command in [#selector(NSResponder.insertNewline(_:)), #selector(NSResponder.cancelOperation(_:)),
                        #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))]
        {
            XCTAssertFalse(coordinator.control(field, textView: fieldEditor, doCommandBy: command), "\(command)")
        }
        // Escape bubbling past the field editor to the bar's exit command is refused too.
        app.closeEditorFindBarFromExitCommand()
        XCTAssertTrue(app.editorFindHost.ui.isBarVisible)
        XCTAssertTrue(fieldEditor.hasMarkedText())
        XCTAssertEqual(EditorReplaceEffectSnapshot(app, textView: editor), before)
        XCTAssertNil(app.editorFindHost.replaceAuthority.lastAuthorizationRecord, "no Replace was attempted")

        // Commit the composition: the value is published once, nothing replaces.
        fieldEditor.insertText("ㄆ", replacementRange: fieldEditor.markedRange())
        XCTAssertFalse(fieldEditor.hasMarkedText())
        try await waitUntil("the committed value reaches App") { app.editorFindHost.ui.replacementText == "NEWㄆ" }
        try await assertRemains("committing composition never replaces") {
            app.currentDocument.text == "hit one hit two"
        }

        // A fresh explicit Return replaces exactly once.
        fieldEditor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(app.currentDocument.text, "NEWㄆ one hit two")
        editor.undoManager?.undo()
        XCTAssertEqual(app.currentDocument.text, "hit one hit two")
        XCTAssertFalse(editor.undoManager?.canUndo == true, "exactly one mutation")

        // Escape without composition closes the bar and keeps the value.
        let escapeEditor = try replacementFieldEditor(in: window)
        escapeEditor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertFalse(app.editorFindHost.ui.isBarVisible)
        XCTAssertEqual(app.editorFindHost.ui.replacementText, "NEWㄆ")
        XCTAssertTrue(app.editorFindHost.ui.isReplaceExpanded)
    }

    /// Bullet 4: composition beginning in any owner while Replace All prepares invalidates the
    /// action by the final pre-commit recheck; nothing fires after composition ends.
    func testHostedMarkedTextBeginningDuringReplaceAllPlanningInvalidatesTheActionInEachOwner() async throws {
        for owner in MarkedTextOwner.allCases {
            let hosted = try await makeHostedReplaceRow(source: String(repeating: "hit ", count: 200))
            let app = hosted.appState
            let editor = try hostedEditor(hosted)
            let before = EditorReplaceEffectSnapshot(app, textView: editor)
            let hold = try await startHeldBarReplaceAll(hosted) {
                try await self.click(EditorFindAccessibility.replaceAllButton, in: hosted.window)
            }
            let writers = app.editorWriterInstallations
            let fieldEditor = try beginComposition(in: owner, of: hosted)
            hold.release()
            await awaitBarReplaceAll(app)
            let result = try XCTUnwrap(app.editorFindHost.replaceBatch.lastResult)
            switch owner {
            case .queryField, .replacementField:
                // Composition changes no source, query, or replacement generation: only the
                // live owner recheck at commit can see it.
                XCTAssertEqual(result, .markedText, "\(owner)")
            case .editor:
                // STTextView posts `didChangeSelection` synchronously from `setMarkedText`, so
                // PR G's preparation-only selection observer advances the authority generation
                // and cancels the token before the plan reaches its final recheck.
                XCTAssertEqual(result, .superseded, "\(owner)")
            }
            XCTAssertEqual(app.editorWriterInstallations, writers, "\(owner): no writer activation")
            XCTAssertEqual(app.currentDocument.text, before.appText, "\(owner)")
            try endComposition(in: owner, of: hosted, fieldEditor: fieldEditor)
            try await assertRemains("\(owner): no post-composition mutation") {
                app.currentDocument.text == before.appText && !app.editorFindHost.replaceBatch.isPreparing
            }
            XCTAssertFalse(editor.undoManager?.canUndo == true, "\(owner)")
        }
    }
}
