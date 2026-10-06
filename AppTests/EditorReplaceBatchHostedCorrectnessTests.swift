import AppKit
@testable import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import WebKit
import XCTest

@MainActor
extension EditorFindHostedGateTests {
    func testHostedReplaceAllSourceOnlyPublishesOnceRescansOnceAndUndoRedoSelection() async throws {
        let hosted = try await makeHostedBatchWorkspace()
        try await assertHostedBatchCommit(hosted, replacement: "LONG", expected: "LONG one LONG two", caret: 4)
    }

    func testHostedReplaceAllSourcePreviewUsesNormalPublication() async throws {
        let hosted = try await makeHostedBatchWorkspace(layoutMode: .sourcePreview)
        let webView = try await waitForView(WKWebView.self, in: hosted.window)
        try await waitUntil("baseline batch preview renders", timeout: 10) {
            try await (webView.evaluateJavaScript("document.body.textContent") as? String)?
                .contains("hit one hit two") == true
        }
        try await assertHostedBatchCommit(hosted, replacement: "NEW", expected: "NEW one NEW two", caret: 3)
        try await waitUntil("batch publication refreshes the live preview", timeout: 10) {
            try await (webView.evaluateJavaScript("document.body.textContent") as? String)?
                .contains("NEW one NEW two") == true
        }
    }

    func testHostedReplaceAllWYSIWYGFoldLinkImageUsesCanonicalSourceAndAutomaticReparse() async throws {
        let source = "**hit** [hit](https://host/hit) ![hit](fixture.png) **untouched**"
        let expected = "**NEW** [NEW](https://host/NEW) ![NEW](fixture.png) **untouched**"
        let hosted = try await makeHostedBatchWorkspace(source: source, layoutMode: .wysiwyg)
        let editor = try hostedEditor(hosted)
        editor.textSelection = NSRange(location: (source as NSString).length, length: 0)
        try await waitUntil("batch starts with folds and an image projection") {
            let model = editor.replacePresentationSnapshot?.styledText.foldPlan
            return model?.regions.contains(where: { !$0.isRevealed }) == true
                && model?.imageRegions.isEmpty == false
        }
        try await waitForHostedBatchPresentationQuiescence(hosted)
        // Replace All intentionally accepts the exact retained set without selecting
        // or revealing each match. The final caret follows the current-match boundary.
        let passes = try HostedBatchPresentationObservation(editor: editor, original: source, expected: expected)
        defer { passes.stop() }
        try await assertHostedBatchCommit(hosted, replacement: "NEW", expected: expected, caret: 5) {
            try await self.waitForHostedBatchPresentationQuiescence(hosted, observation: passes)
            XCTAssertEqual(passes.suspensions, 1, "one full batch attribute suspension")
            XCTAssertEqual(passes.reapplications, 1, "one authoritative post-write fold pass")
        }
        try await waitUntil("batch source reparses automatically") {
            editor.replacePresentationSnapshot?.sourceRevision == hosted.appState.currentDocument.version
        }
        assertHostedBatchRawSource(editor, source: expected)
        editor.textSelection = NSRange(location: 0, length: (expected as NSString).length)
        assertHostedBatchRawSource(editor, source: expected)
    }

    func testHostedReplaceAllAllIdenticalHasNoWriterRevisionUndoRescanSelectionOrOrdinalEffects() async throws {
        let hosted = try await makeHostedBatchWorkspace()
        let app = hosted.appState
        let editor = try hostedEditor(hosted)
        let before = EditorReplaceEffectSnapshot(app, textView: editor)
        let writers = app.editorWriterInstallations
        let schedules = app.editorFindHost.controller.replacementScheduleCount
        let result = await app.performEditorReplaceAll(replacement: "hit")
        guard case let .delivered(.noChanges(plan)) = result else {
            return XCTFail("expected No changes, got \(result)")
        }
        XCTAssertEqual(plan.changedCount, 0)
        XCTAssertEqual(plan.totalCount, 2)
        XCTAssertEqual(EditorReplaceEffectSnapshot(app, textView: editor), before)
        XCTAssertEqual(app.editorWriterInstallations, writers)
        XCTAssertEqual(app.editorFindHost.controller.replacementScheduleCount, schedules)
    }

    func testHostedReplaceAllMixedLiteralIdentityChangesOnlyDifferingRanges() async throws {
        let hosted = try await makeHostedBatchWorkspace(source: "hit HIT hit", query: "hit")
        // Default Find uses smart case, so this lower-case query retains all three.
        let result = await hosted.appState.performEditorReplaceAll(replacement: "hit")
        guard case let .delivered(.replaced(plan)) = result else {
            return XCTFail("expected a mixed batch, got \(result)")
        }
        XCTAssertEqual(plan.totalCount, 3)
        XCTAssertEqual(plan.changedCount, 1)
        XCTAssertEqual(plan.differingRanges, [NSRange(location: 4, length: 3)])
        XCTAssertEqual(hosted.appState.currentDocument.text, "hit hit hit")
        let editor = try hostedEditor(hosted)
        editor.undoManager?.undo()
        XCTAssertEqual(hosted.appState.currentDocument.text, "hit HIT hit")
        XCTAssertFalse(editor.undoManager?.canUndo == true)
    }

    func testHostedReplaceAllAllowsExactlyTenThousandAndRefusesOverflowWithoutMutation() async throws {
        let exact = String(repeating: "hit ", count: 10000)
        let hosted = try await makeHostedBatchWorkspace(source: exact)
        XCTAssertEqual(hosted.appState.editorFindHost.controller.session?.total, 10000)
        XCTAssertEqual(hosted.appState.editorFindHost.controller.session?.isTruncated, false)
        try await assertHostedBatchCommit(hosted, replacement: "x", expected: String(repeating: "x ", count: 10000),
                                          caret: 1)
        let overflow = try await makeHostedBatchWorkspace(source: String(repeating: "hit ", count: 10001))
        let editor = try hostedEditor(overflow)
        let before = EditorReplaceEffectSnapshot(overflow.appState, textView: editor)
        XCTAssertEqual(overflow.appState.editorFindHost.controller.session?.isTruncated, true)
        let result = await overflow.appState.performEditorReplaceAll(replacement: "x")
        XCTAssertEqual(result, .invalidPlan(.truncatedSession))
        XCTAssertEqual(EditorReplaceEffectSnapshot(overflow.appState, textView: editor), before)
    }

    func testHostedReplaceAllLargeFixtureEightThousandNineHundredTwentyOneWithMaximumReplacement() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "large-1mb", withExtension: "md"))
        let source = try String(contentsOf: url, encoding: .utf8)
        let hosted = try await makeHostedBatchWorkspace(source: source, query: "an")
        let find = try XCTUnwrap(hosted.appState.editorFindHost.controller.session)
        XCTAssertEqual(find.total, 8921)
        XCTAssertFalse(find.isTruncated)
        let replacement = String(repeating: "x", count: 256)
        let expected = source.replacingOccurrences(of: "an", with: replacement)
        let first = try XCTUnwrap(find.currentMatch).range
        try await assertHostedBatchCommit(hosted, replacement: replacement, expected: expected,
                                          caret: first.location + 256, timeout: 30)
    }

    func testHostedReplaceAllCanonicalEquivalentUnequalRangesMapsThirdMatchCaret() async throws {
        let hosted = try await makeHostedBatchWorkspace(source: "e\u{301} é e\u{301}", query: "é")
        let app = hosted.appState
        app.stepEditorFindFromBarControl(.next)
        app.stepEditorFindFromBarControl(.next)
        try await waitUntil("third unequal UTF-16 match is selected") {
            app.editorFindHost.controller.session?.currentOrdinal == 3
                && self.appliedRange(in: hosted.window) == NSRange(location: 5, length: 2)
        }
        try await assertHostedBatchCommit(hosted, replacement: "X", expected: "X X X", caret: 5)
    }

    func testHostedReplaceAllReplacementContainingQueryIsNotRecursivelyReplaced() async throws {
        let hosted = try await makeHostedBatchWorkspace()
        try await assertHostedBatchCommit(
            hosted,
            replacement: "hit hit",
            expected: "hit hit one hit hit two",
            caret: 7
        ) {
            XCTAssertEqual(hosted.appState.editorFindHost.controller.session?.total, 4)
            XCTAssertNil(hosted.appState.editorFindHost.controller.session?.currentOrdinal)
        }
    }

    func testHostedReplaceAllUndoDoesNotMergeWithPriorTyping() async throws {
        let hosted = try await makeHostedBatchWorkspace()
        let app = hosted.appState
        let editor = try hostedEditor(hosted)
        let source = app.currentDocument.text
        editor.insertText("!", replacementRange: NSRange(location: (source as NSString).length, length: 0))
        try await waitUntil("typing source rescans before explicit batch") {
            app.editorFindHost.controller.session != nil
                && app.editorFindHost.controller.documentBinding.revision == UInt64(app.currentDocument.version)
        }
        let typed = app.currentDocument.text
        let result = await app.performEditorReplaceAll(replacement: "NEW")
        guard case .delivered(.replaced) = result else { return XCTFail("expected batch, got \(result)") }
        editor.undoManager?.undo()
        XCTAssertEqual(app.currentDocument.text, typed, "one Undo restores the batch's exact dirty baseline")
        XCTAssertTrue(app.currentDocument.isDirty)
        XCTAssertTrue(editor.undoManager?.canUndo == true, "earlier typing history is preserved")
        editor.undoManager?.undo()
        XCTAssertEqual(app.currentDocument.text, source)
        XCTAssertFalse(app.currentDocument.isDirty)
    }

    func testHostedReplaceAllOversizedAndNewlineReplacementRefuseBeforeAnyWrite() async throws {
        let hosted = try await makeHostedBatchWorkspace()
        let before = try EditorReplaceEffectSnapshot(hosted.appState, textView: hostedEditor(hosted))
        let oversized = await hosted.appState.performEditorReplaceAll(replacement: String(repeating: "x", count: 257))
        XCTAssertEqual(oversized, .invalidPlan(.invalidReplacement(.exceedsMaximumUTF16Length)))
        let newline = await hosted.appState.performEditorReplaceAll(replacement: "a\nb")
        XCTAssertEqual(newline, .invalidPlan(.invalidReplacement(.containsNewline)))
        XCTAssertEqual(try EditorReplaceEffectSnapshot(hosted.appState, textView: hostedEditor(hosted)), before)
    }

    func assertHostedBatchCommit(
        _ hosted: HostedReplaceWorkspace,
        replacement: String,
        expected: String,
        caret: Int,
        timeout: TimeInterval = 10,
        beforeUndo: () async throws -> Void = {}
    ) async throws {
        let app = hosted.appState
        let editor = try hostedEditor(hosted)
        let controller = app.editorFindHost.controller
        let source = app.currentDocument.text
        let selection = editor.selectedRange()
        let wasDirty = app.currentDocument.isDirty
        let revision = app.currentDocument.version
        let schedules = controller.replacementScheduleCount
        let scans = controller.replacementEngineInvocationCount
        let publications = controller.recordedReplacementPublicationCount
        let result = await app.performEditorReplaceAll(replacement: replacement)
        guard case .delivered(.replaced) = result else { return XCTFail("expected batch commit, got \(result)") }
        XCTAssertEqual(app.editorFindHost.replaceAuthority.lastAuthorizationRecord?.checkpoints, [.validation, .commit])
        XCTAssertEqual(app.currentDocument.text, expected)
        XCTAssertEqual(app.currentDocument.version, revision + 1, "one authoritative publication")
        XCTAssertEqual(controller.recordedReplacementPublicationCount, publications + 1)
        XCTAssertEqual(controller.replacementScheduleCount, schedules + 1)
        let rescanBegan = Date()
        try await waitUntil("one batch rescan clears current and stores the mapped anchor", timeout: timeout) {
            controller.replacementEngineInvocationCount == scans + 1
                && controller.documentBinding.revision == UInt64(app.currentDocument.version)
                && controller.session != nil
                && controller.session?.currentOrdinal == nil
        }
        let rescanMilliseconds = Date().timeIntervalSince(rescanBegan) * 1000
        XCTAssertEqual(controller.session?.caretAnchorUTF16, caret)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: caret, length: 0))
        assertHostedBatchRawSource(editor, source: expected)
        let presentationBegan = Date()
        if editor.wysiwygZeroWidthContentStorageDelegate != nil {
            try await waitUntil("authoritative post-batch source presentation applies", timeout: timeout) {
                editor.replacePresentationSnapshot?.sourceRevision == app.currentDocument.version
            }
        }
        let presentationMilliseconds = Date().timeIntervalSince(presentationBegan) * 1000
        let state = app.editorFindHost.replaceBatch
        print(
            "Replace All informational timing: preparation=\(state.preparationMilliseconds) ms commit=\(state.commitMilliseconds) ms rescan-drain=\(rescanMilliseconds) ms presentation-drain=\(presentationMilliseconds) ms"
        )
        try await beforeUndo()
        editor.undoManager?.undo()
        XCTAssertEqual(app.currentDocument.text, source)
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertEqual(app.currentDocument.isDirty, wasDirty)
        XCTAssertFalse(editor.undoManager?.canUndo == true, "exactly one undo step")
        XCTAssertTrue(editor.undoManager?.canRedo == true)
        editor.undoManager?.redo()
        XCTAssertEqual(app.currentDocument.text, expected)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: caret, length: 0))
    }
}
