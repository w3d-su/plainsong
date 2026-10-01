import AppKit
@testable import EditorKit
import MarkdownCore
@testable import Plainsong
@testable import PreviewKit
import WebKit
import XCTest

@MainActor
extension EditorFindHostedGateTests {
    func testHostedReplaceFoldedDelimiterThroughDispatcherAndAutomaticReparseUndoRedo() async throws {
        try await assertHostedWYSIWYGReplace(source: "Intro **文字😀** tail", query: "文字😀", replacement: "新🦊",
                                             kind: .strong)
    }

    func testHostedReplaceLinkDestinationThroughDispatcherWithoutURLNormalization() async throws {
        try await assertHostedWYSIWYGReplace(source: "Intro [文字😀](https://host/a%2Fb_(c)) tail", query: "%2F",
                                             replacement: "%2f", kind: .link)
    }

    func testHostedReplaceImageThroughDispatcherAndAutomaticThumbnailUndoRedo() async throws {
        // A valid local raster uses the production WorkspaceKit-backed thumbnail provider.
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let hosted = try await makeHostedReplaceWorkspace(source: "Intro ![文字😀](fixture.png) tail", query: "文字😀",
                                                          assets: ["fixture.png": png], layoutMode: .wysiwyg)
        try await waitForHostedReplaceWYSIWYG(hosted)
        try await waitForHostedReplaceAuthorization(hosted)
        let editor = try hostedEditor(hosted)
        editor.textSelection = NSRange(location: 0, length: 0)
        try await waitUntil("production image marker installs outside selection") {
            self.hostedImageMarker(editor) != nil
        }
        try await waitForHostedReplaceAuthorization(hosted)
        let before = hosted.appState.currentDocument.text
        let match = try XCTUnwrap(hosted.appState.editorFindHost.controller.session?.currentMatch?.range)
        XCTAssertEqual(
            hosted.appState.performEditorReplace(replacement: "新🦊"),
            .delivered(.navigatedToCurrentMatch(match))
        )
        XCTAssertEqual(hosted.appState.currentDocument.text, before)
        try await waitForHostedReveal(hosted, match: match)
        XCTAssertNil(hostedImageMarker(editor))
        try await commitHostedReplaceAndUndoRedo(hosted, replacement: "新🦊")
        editor.textSelection = NSRange(location: 0, length: 0)
        try await waitUntil("valid post-write image thumbnails after selection leaves") {
            self.hostedImageMarker(editor)?.altText == "新🦊"
        }
    }

    func testHostedReplaceInvalidImageRemainsRawEditableAfterAutomaticReparse() async throws {
        let hosted = try await makeHostedReplaceWorkspace(
            source: "Intro ![alt](fixture.png) tail",
            query: "](fixture.png)",
            layoutMode: .wysiwyg
        )
        try await waitForHostedReplaceWYSIWYG(hosted)
        try await waitForHostedReplaceAuthorization(hosted)
        let editor = try hostedEditor(hosted)
        editor.textSelection = NSRange(location: 0, length: 0)
        try await waitUntil("image placeholder projects") { self.hostedImageMarker(editor) != nil }
        let match = try XCTUnwrap(hosted.appState.editorFindHost.controller.session?.currentMatch?.range)
        XCTAssertEqual(
            hosted.appState.performEditorReplace(replacement: "]fixture.png)"),
            .delivered(.navigatedToCurrentMatch(match))
        )
        try await waitForHostedReveal(hosted, match: match)
        try await commitHostedReplaceAndUndoRedo(hosted, replacement: "]fixture.png)")
        editor.textSelection = NSRange(location: 0, length: 0)
        try await waitUntil("invalid post-write image reparse stays raw") {
            editor.replacePresentationSnapshot?.styledText.foldPlan?.imageRegions.isEmpty == true
                && self.hostedImageMarker(editor) == nil
        }
        let source = hosted.appState.currentDocument.text
        editor.insertText("!", replacementRange: NSRange(location: (source as NSString).length, length: 0))
        XCTAssertEqual(hosted.appState.currentDocument.text, source + "!")
    }

    func testHostedReplaceInvalidDelimiterStaysRawWithoutMarkdownRepair() async throws {
        let hosted = try await makeHostedReplaceWorkspace(
            source: "Intro **one** tail",
            query: "**one",
            layoutMode: .wysiwyg
        )
        try await waitForHostedReplaceWYSIWYG(hosted)
        let match = try XCTUnwrap(hosted.appState.editorFindHost.controller.session?.currentMatch?.range)
        try await waitForHostedReveal(hosted, match: match)
        try await commitHostedReplaceAndUndoRedo(hosted, replacement: "one")
        try await waitForHostedReplaceAuthorization(hosted)
        let editor = try hostedEditor(hosted)
        editor.textSelection = NSRange(location: 0, length: 0)
        try await waitUntil("malformed delimiter remains raw after post-write parse") {
            editor.replacePresentationSnapshot?.sourceRevision == hosted.appState.currentDocument.version
                && editor.replacePresentationSnapshot?.styledText.foldPlan?.regions.isEmpty == true
        }
        XCTAssertEqual(hosted.appState.currentDocument.text, "Intro one** tail")
    }

    /// PR F review: the heading owner is revealed by the selection, while the strong it
    /// contains is untouched by the match and stays folded. Replace must still commit.
    func testHostedReplaceInsideRevealedHeadingWithNestedFoldedStrongCommits() async throws {
        let hosted = try await makeHostedReplaceWorkspace(source: "# Title **bold** word", query: "word",
                                                          layoutMode: .wysiwyg)
        try await waitForHostedReplaceWYSIWYG(hosted)
        try await waitForHostedReplaceAuthorization(hosted)
        let editor = try hostedEditor(hosted)
        let source = hosted.appState.currentDocument.text
        editor.textSelection = NSRange(location: (source as NSString).length, length: 0)
        try await waitUntil("heading and nested strong fold through production presentation") {
            let regions = editor.replacePresentationSnapshot?.styledText.foldPlan?.regions ?? []
            return regions.count == 2 && regions.allSatisfy { !$0.isRevealed }
        }
        let match = try XCTUnwrap(hosted.appState.editorFindHost.controller.session?.currentMatch?.range)
        XCTAssertEqual(
            hosted.appState.performEditorReplace(replacement: "WORD"),
            .delivered(.navigatedToCurrentMatch(match))
        )
        XCTAssertEqual(hosted.appState.currentDocument.text, source)
        try await waitForHostedReveal(hosted, match: match)
        let regions = try XCTUnwrap(editor.replacePresentationSnapshot?.styledText.foldPlan?.regions)
        XCTAssertEqual(regions.first { $0.kind == .heading(level: 1) }?.isRevealed, true)
        let strong = try XCTUnwrap(regions.first { $0.kind == .strong })
        XCTAssertFalse(strong.isRevealed, "the untouched nested strong stays folded at commit")
        let storage = try XCTUnwrap(MarkdownTextView.textStorage(of: editor))
        for range in strong.foldRanges {
            XCTAssertTrue(WYSIWYGInlineFoldPresentation.containsFoldedDelimiterAttributes(
                storage.attributes(at: range.location, effectiveRange: nil)
            ))
        }
        try await commitHostedReplaceAndUndoRedo(hosted, replacement: "WORD")
        XCTAssertEqual(hosted.appState.currentDocument.text, "# Title **bold** WORD")
        editor.textSelection = NSRange(location: (hosted.appState.currentDocument.text as NSString).length, length: 0)
        try await waitUntil("heading and nested strong refold from post-write source") {
            let regions = editor.replacePresentationSnapshot?.styledText.foldPlan?.regions ?? []
            return editor.replacePresentationSnapshot?.sourceRevision == hosted.appState.currentDocument.version
                && regions.count == 2 && regions.allSatisfy { !$0.isRevealed }
        }
    }

    func testHostedReplaceSourceOnlyAndSourcePreviewPublishNormally() async throws {
        for mode in [EditorLayoutMode.sourceOnly, .sourcePreview] {
            let hosted = try await makeHostedReplaceWorkspace(
                source: "# Hosted\n\nhit one hit two",
                query: "hit",
                layoutMode: mode
            )
            try await focusEditorOnCurrentMatch(hosted, window: hosted.window)
            let webView: WKWebView?
            if mode == .sourcePreview {
                webView = try await waitForView(WKWebView.self, in: hosted.window)
                if let webView {
                    try await waitUntil("baseline preview content is rendered", timeout: 8) {
                        try await (webView.evaluateJavaScript("document.body.textContent") as? String)?
                            .contains("hit one hit two") == true
                    }
                }
            } else {
                webView = nil
            }
            try await waitForHostedReplaceAuthorization(hosted)
            let controller = hosted.appState.editorFindHost.controller
            let schedules = controller.replacementScheduleCount
            guard case .delivered(.replaced) = hosted.appState.performEditorReplace(replacement: "NEW") else {
                return XCTFail("production dispatch must replace in \(mode)")
            }
            XCTAssertEqual(hosted.appState.currentDocument.text, "# Hosted\n\nNEW one hit two")
            XCTAssertEqual(controller.replacementScheduleCount, schedules + 1)
            XCTAssertEqual(try MarkdownTextView.textStorage(of: hostedEditor(hosted))?.string,
                           hosted.appState.currentDocument.text)
            if let webView {
                try await waitUntil("normal publication updates live preview", timeout: 8) {
                    try await (webView.evaluateJavaScript("document.body.textContent") as? String)?
                        .contains("NEW one hit two") == true
                }
            }
        }
    }

    private func assertHostedWYSIWYGReplace(source: String, query: String, replacement: String,
                                            kind: WYSIWYGFoldRegion.Kind) async throws
    {
        let hosted = try await makeHostedReplaceWorkspace(source: source, query: query, layoutMode: .wysiwyg)
        try await waitForHostedReplaceWYSIWYG(hosted)
        try await waitForHostedReplaceAuthorization(hosted)
        let editor = try hostedEditor(hosted)
        editor.textSelection = NSRange(location: 0, length: 0)
        try await waitUntil("owning region folds through production presentation") {
            editor.replacePresentationSnapshot?.styledText.foldPlan?.regions.contains {
                $0.kind == kind && !$0.isRevealed
            } == true
        }
        let match = try XCTUnwrap(hosted.appState.editorFindHost.controller.session?.currentMatch?.range)
        XCTAssertEqual(
            hosted.appState.performEditorReplace(replacement: replacement),
            .delivered(.navigatedToCurrentMatch(match))
        )
        XCTAssertEqual(hosted.appState.currentDocument.text, source)
        XCTAssertFalse(editor.undoManager?.canUndo == true)
        try await waitForHostedReveal(hosted, match: match)
        try await commitHostedReplaceAndUndoRedo(hosted, replacement: replacement)
        editor.textSelection = NSRange(location: 0, length: 0)
        try await waitUntil("valid construct refolds from post-write source") {
            editor.replacePresentationSnapshot?.sourceRevision == hosted.appState.currentDocument.version
                && editor.replacePresentationSnapshot?.styledText.foldPlan?.regions.contains {
                    $0.kind == kind && !$0.isRevealed
                } == true
        }
    }

    private func waitForHostedReplaceAuthorization(_ hosted: HostedReplaceWorkspace) async throws {
        try await waitUntil("initial external inspection settles before the explicit command") {
            hosted.appState.editorReplaceAuthorizationDecision(for: hosted.appState.currentDocument) == .allowed
        }
    }

    private func waitForHostedReplaceWYSIWYG(_ hosted: HostedReplaceWorkspace) async throws {
        try await waitUntil("production Experimental WYSIWYG is installed") {
            self.editorTextView(in: hosted.window)?.wysiwygZeroWidthContentStorageDelegate != nil
                && self.editorTextView(in: hosted.window)?.replacePresentationSnapshot?.styledText.foldPlan != nil
        }
        try await focusEditorOnCurrentMatch(hosted, window: hosted.window)
    }

    private func waitForHostedReveal(_ hosted: HostedReplaceWorkspace, match: NSRange) async throws {
        try await waitUntil("post-selection complete owning-source reveal applies") {
            guard let editor = self.editorTextView(in: hosted.window),
                  let coordinator = editor.textDelegate as? MarkdownTextViewCoordinator else { return false }
            return editor.selectedRange() == match && coordinator.isReplaceRangeRevealed(match, in: editor)
        }
        let editor = try hostedEditor(hosted)
        let coordinator = try XCTUnwrap(editor.textDelegate as? MarkdownTextViewCoordinator)
        XCTAssertTrue(
            coordinator.isReplaceRangeRevealed(match, in: editor),
            hostedPresentationDiagnostics(hosted, editor)
        )
    }

    private func commitHostedReplaceAndUndoRedo(_ hosted: HostedReplaceWorkspace, replacement: String) async throws {
        let app = hosted.appState
        let editor = try hostedEditor(hosted)
        let source = app.currentDocument.text
        let originalPlan = try XCTUnwrap(editor.replacePresentationSnapshot?.styledText.foldPlan)
        let match = try XCTUnwrap(app.editorFindHost.controller.session?.currentMatch?.range)
        let expected = (source as NSString).replacingCharacters(in: match, with: replacement)
        try await waitForHostedReplaceAuthorization(hosted)
        let schedules = app.editorFindHost.controller.replacementScheduleCount
        guard case .delivered(.replaced) = app.performEditorReplace(replacement: replacement) else {
            return XCTFail("second explicit action must commit through App and dispatcher")
        }
        XCTAssertEqual(app.editorFindHost.replaceAuthority.lastAuthorizationRecord?.checkpoints, [.validation, .commit])
        XCTAssertEqual(app.currentDocument.text, expected)
        XCTAssertEqual(app.editorFindHost.controller.replacementScheduleCount, schedules + 1)
        try await waitUntil("post-write authoritative source reparses") {
            editor.replacePresentationSnapshot?.sourceRevision == app.currentDocument.version
        }
        XCTAssertEqual(editor.replacePresentationSnapshot?.sourceRevision, app.currentDocument.version,
                       hostedPresentationDiagnostics(hosted, editor))
        assertHostedRawValue(editor, source: expected)
        editor.undoManager?.undo()
        XCTAssertEqual(app.currentDocument.text, source)
        try await waitUntil("undo source reparses automatically") {
            editor.replacePresentationSnapshot?.sourceRevision == app.currentDocument.version
        }
        assertHostedRawValue(editor, source: source)
        XCTAssertEqual(editor.replacePresentationSnapshot?.styledText.foldPlan?.regions.map(\.sourceRange),
                       originalPlan.regions.map(\.sourceRange))
        XCTAssertEqual(editor.replacePresentationSnapshot?.styledText.foldPlan?.imageRegions.map(\.sourceRange),
                       originalPlan.imageRegions.map(\.sourceRange))
        XCTAssertFalse(editor.undoManager?.canUndo == true)
        XCTAssertTrue(editor.undoManager?.canRedo == true)
        editor.undoManager?.redo()
        XCTAssertEqual(app.currentDocument.text, expected)
        try await waitUntil("redo source reparses automatically") {
            editor.replacePresentationSnapshot?.sourceRevision == app.currentDocument.version
        }
        XCTAssertEqual(editor.replacePresentationSnapshot?.sourceRevision, app.currentDocument.version,
                       hostedPresentationDiagnostics(hosted, editor))
        assertHostedRawValue(editor, source: expected)
    }

    private func hostedPresentationDiagnostics(_ hosted: HostedReplaceWorkspace,
                                               _ editor: MarkdownSTTextView) -> String
    {
        let coordinator = editor.textDelegate as? MarkdownTextViewCoordinator
        return "source=\(hosted.appState.currentDocument.text) selection=\(editor.selectedRange()) editing=\(String(describing: coordinator?.isUserEditing)) applied=\(String(describing: coordinator?.lastAppliedHighlightRevision)) currentView=\(editor === editorTextView(in: hosted.window)) parsed=\(String(describing: editor.replacePresentationSnapshot?.styledText.range))"
    }

    private func assertHostedRawValue(_ editor: MarkdownSTTextView, source: String) {
        XCTAssertEqual(MarkdownTextView.textStorage(of: editor)?.string, source)
        XCTAssertEqual(editor.accessibilityValue() as? String, source)
        XCTAssertFalse(source.contains("\u{FFFC}"))
        XCTAssertFalse(source.contains("\u{200B}"))
        let selection = editor.selectedRange()
        let length = (source as NSString).length
        guard selection.location >= 0, selection.location <= length,
              selection.length <= length - selection.location
        else {
            return XCTFail("selection must remain a valid raw UTF-16 range")
        }
        let selected = (source as NSString).substring(with: selection)
        XCTAssertEqual(editor.accessibilitySelectedText(), selected)
        if selection.length > 0 {
            let board = NSPasteboard(name: NSPasteboard.Name("ReplaceHosted-\(UUID().uuidString)"))
            XCTAssertTrue(editor.writeSelection(to: board, types: [.string]))
            XCTAssertEqual(board.string(forType: .string), selected)
        }
    }

    private func hostedImageMarker(_ editor: MarkdownSTTextView) -> WYSIWYGImagePresentationMarker? {
        guard let storage = MarkdownTextView.textStorage(of: editor) else { return nil }
        var marker: WYSIWYGImagePresentationMarker?
        storage.enumerateAttribute(WYSIWYGImagePresentationMarker.attribute,
                                   in: NSRange(location: 0, length: storage.length))
        { value, _, _ in
            if let current = value as? WYSIWYGImagePresentationMarker,
               current.generation == editor.wysiwygZeroWidthContentStorageDelegate?.imagePresentationGeneration
            {
                marker = marker ?? current
            }
        }
        return marker
    }
}
