import AppKit
@testable import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import XCTest

/// Handoff 21: the production scheduler restores presentation even though the rejected
/// publication leaves the App binding's source and revision unchanged.
@MainActor
extension EditorFindHostedGateTests {
    func testHostedRejectedReplaceAutomaticallyRestoresWYSIWYGFoldsLinksAndImageMarkers() async throws {
        let source = "Intro **one** and *two* [docs](https://host/a%2Fb) ![alt](fixture.png) tail"
        let hosted = try await makeHostedEditorWorkspace(
            source: source, query: "one", assets: ["fixture.png": reconciledFixturePNG()], layoutMode: .wysiwyg
        )
        let editor = try hostedEditor(hosted)
        let coordinator = try XCTUnwrap(editor.textDelegate as? MarkdownTextViewCoordinator)
        let match = try XCTUnwrap(hosted.appState.editorFindHost.controller.session?.currentMatch?.range)
        try await waitUntil("Replace owner reveals while untouched folds and image projection remain") {
            coordinator.isReplaceRangeRevealed(match, in: editor)
                && !self.reconciledPresentation(editor).foldedRanges.isEmpty
                && self.reconciledPresentation(editor).imageVisualStates.contains {
                    if case .ready = $0 { return true }
                    return false
                }
        }

        try await assertHostedRejectedReplaceAutomaticallyRestoresPresentation(hosted, replacement: "ONE")
    }

    func testHostedRejectedReplaceAutomaticallyRestoresSourceHighlightWithoutTypingOrSelectionChange() async throws {
        let hosted = try await makeHostedEditorWorkspace(
            source: "# Heading\n\nIntro **one** and `code` tail",
            query: "one",
            layoutMode: .sourceOnly
        )

        try await assertHostedRejectedReplaceAutomaticallyRestoresPresentation(hosted, replacement: "ONE")
    }

    private func assertHostedRejectedReplaceAutomaticallyRestoresPresentation(
        _ hosted: HostedReplaceWorkspace,
        replacement: String
    ) async throws {
        let appState = hosted.appState
        let session = appState.currentDocument
        let source = session.text
        let sourceRevision = session.version
        let editor = try hostedEditor(hosted)
        let storage = try XCTUnwrap(MarkdownTextView.textStorage(of: editor))
        let coordinator = try XCTUnwrap(editor.textDelegate as? MarkdownTextViewCoordinator)
        try await waitForHostedReplaceObservationQuiescence(hosted)
        try await settleReconciledHighlight(coordinator)
        let presentationBefore = reconciledPresentation(editor)
        let revisionBefore = try XCTUnwrap(coordinator.lastAppliedHighlightRevision)
        let bindingBefore = coordinator.currentDocumentBindingInstallation
        let findSessionBefore = appState.editorFindHost.controller.session
        let replacementSchedulesBefore = appState.editorFindHost.controller.replacementScheduleCount
        let match = try XCTUnwrap(findSessionBefore?.currentMatch?.range)
        assertReconciledFindDecoration(in: storage, match: match)
        let intercepted = ReconciledPublicationInterception()
        let observer = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: storage,
            queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                guard intercepted.proposedSource == nil,
                      !ExactSourceText.matches(storage.string, source)
                else { return }
                // Native insertion has passed App's writer preflight, but publication
                // has not run. Removing that exact writer makes App's normal callback
                // reject the proposed source and return its unchanged authoritative one.
                intercepted.proposedSource = storage.string
                appState.editorWriterInstallations[ObjectIdentifier(session)] = nil
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let result = appState.performEditorReplace(replacement: replacement)

        XCTAssertEqual(intercepted.proposedSource,
                       (source as NSString).replacingCharacters(in: match, with: replacement))
        XCTAssertEqual(result, .delivered(.refused(.writeNotApplied)))
        XCTAssertEqual(session.text, source)
        XCTAssertEqual(session.version, sourceRevision, "the App binding cannot schedule through a text change")
        XCTAssertEqual(coordinator.currentDocumentBindingInstallation, bindingBefore)
        XCTAssertEqual(coordinator.lastAppliedHighlightRevision, revisionBefore, "reparse remains asynchronous")
        XCTAssertEqual(storage.string, source)
        XCTAssertEqual(editor.accessibilityValue() as? String, source)
        XCTAssertFalse(editor.undoManager?.canUndo == true)
        XCTAssertFalse(editor.undoManager?.canRedo == true)
        let selectionAfterRestore = editor.selectedRange()
        let pending = reconciledPresentation(editor)
        XCTAssertTrue(pending.foldedRanges.isEmpty, "pending presentation exposes raw source")
        XCTAssertTrue(pending.imageMarkerRanges.isEmpty, "no image marker survives the whole-source reset")

        // Observe only: no edit, selection change, representable update, explicit highlight
        // application, or manual scheduling is used to recover the cleared attributes.
        try await waitUntil("normal scheduler automatically restores rejected-publication presentation") {
            coordinator.lastAppliedHighlightRevision != revisionBefore
                && self.reconciledPresentation(editor).imageVisualStates == presentationBefore.imageVisualStates
        }
        assertReconciledFindDecoration(in: storage, match: match)
        let restored = reconciledPresentation(editor)
        XCTAssertEqual(restored.syntax, presentationBefore.syntax)
        XCTAssertEqual(restored.foldedRanges, presentationBefore.foldedRanges)
        XCTAssertEqual(restored.imageMarkerRanges, presentationBefore.imageMarkerRanges)
        XCTAssertEqual(restored.imageVisualStates, presentationBefore.imageVisualStates)
        XCTAssertEqual(editor.selectedRange(), selectionAfterRestore)
        XCTAssertEqual(session.text, source)
        XCTAssertEqual(session.version, sourceRevision)
        XCTAssertEqual(coordinator.currentDocumentBindingInstallation, bindingBefore)
        XCTAssertEqual(appState.editorFindHost.controller.session, findSessionBefore)
        XCTAssertEqual(appState.editorFindHost.controller.replacementScheduleCount, replacementSchedulesBefore)
        XCTAssertFalse(editor.undoManager?.canUndo == true)
        XCTAssertFalse(editor.undoManager?.canRedo == true)
        try assertReconciledPresentationMatchesFreshParse(hosted, editor: editor, coordinator: coordinator)
    }

    func assertReconciledFindDecoration(in storage: NSTextStorage, match: NSRange) {
        storage.enumerateAttribute(EditorFindMatchHighlightMarker.attribute, in: match) { value, _, _ in
            XCTAssertNotNil(value, "The current Find match must retain decoration after the restore")
        }
    }

    func assertReconciledPresentationMatchesFreshParse(
        _ hosted: HostedReplaceWorkspace,
        editor: MarkdownSTTextView,
        coordinator: MarkdownTextViewCoordinator
    ) throws {
        let storage = try XCTUnwrap(MarkdownTextView.textStorage(of: editor))
        let preferences = hosted.appState.preferences
        let presentation = EditorPresentationPolicy.resolve(
            usesWYSIWYGPresentation: editor.wysiwygZeroWidthContentStorageDelegate != nil
        )
        let fresh = MarkdownSyntaxHighlighter(
            theme: .builtIn(preferences.editorTheme),
            baseFont: MarkdownSyntaxHighlighter.editorFont(
                named: preferences.editorFontName,
                size: CGFloat(preferences.editorFontSize)
            )
        ).highlight(
            hosted.appState.currentDocument.text,
            fileKind: .markdown,
            visibleRange: NSRange(location: 0, length: storage.length),
            developmentPresentation: presentation,
            selection: editor.selectedRange()
        )
        // This is an independent oracle; its attributes are never applied to the editor.
        XCTAssertEqual(coordinator.lastAppliedHighlightFoldPlan, fresh.foldPlan)
        let expected = NSMutableAttributedString(attributedString: NSAttributedString(fresh.text))
        // Foundation's AttributedString bridge does not retain the custom fold marker.
        // The normal storage apply restores it from the parse's independent fold plan.
        if let foldPlan = fresh.foldPlan {
            WYSIWYGInlineFoldPresentation.applyFoldedDelimiterAttributes(
                plan: foldPlan, visibleRange: fresh.range, to: expected
            )
        }
        XCTAssertEqual(reconciledSyntaxAttributes(storage), reconciledSyntaxAttributes(expected))
    }

    func settleReconciledHighlight(_ coordinator: MarkdownTextViewCoordinator) async throws {
        let deadline = Date().addingTimeInterval(3)
        var revision = coordinator.lastAppliedHighlightRevision
        var quietSince = Date()
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
            if coordinator.lastAppliedHighlightRevision != revision {
                revision = coordinator.lastAppliedHighlightRevision
                quietSince = Date()
            } else if Date().timeIntervalSince(quietSince) >= 0.15 {
                return
            }
        }
        XCTFail("Initial highlight never settled before the rejection probe")
    }

    func reconciledPresentation(_ editor: MarkdownSTTextView) -> ReconciledHostedPresentation {
        guard let storage = MarkdownTextView.textStorage(of: editor) else {
            return ReconciledHostedPresentation(syntax: NSAttributedString(string: ""), foldedRanges: [],
                                                imageMarkerRanges: [], imageVisualStates: [])
        }
        var folded = IndexSet()
        var images = IndexSet()
        var imageVisualStates: [WYSIWYGImagePresentationMarker.VisualState] = []
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, range, _ in
            if WYSIWYGInlineFoldPresentation.containsFoldedDelimiterAttributes(attributes) {
                folded.insert(integersIn: range.location ..< NSMaxRange(range))
            }
            if let marker = attributes[WYSIWYGImagePresentationMarker.attribute] as? WYSIWYGImagePresentationMarker,
               marker.generation == editor.wysiwygZeroWidthContentStorageDelegate?.imagePresentationGeneration
            {
                images.insert(integersIn: range.location ..< NSMaxRange(range))
                imageVisualStates.append(marker.visualState)
            }
        }
        return ReconciledHostedPresentation(syntax: reconciledSyntaxAttributes(storage),
                                            foldedRanges: folded, imageMarkerRanges: images,
                                            imageVisualStates: imageVisualStates)
    }

    func reconciledFixturePNG() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        for x in 0 ..< 8 {
            for y in 0 ..< 8 {
                bitmap.setColor(.red, atX: x, y: y)
            }
        }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    func reconciledSyntaxAttributes(_ text: NSAttributedString) -> NSAttributedString {
        let syntax = NSMutableAttributedString(string: text.string)
        let keys: Set<NSAttributedString.Key> = [
            .font, .foregroundColor, .backgroundColor, .underlineStyle, .strikethroughStyle,
            WYSIWYGInlineFoldPresentation.foldedDelimiterAttribute,
        ]
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            var selected = attributes.filter { keys.contains($0.key) }
            if attributes[EditorFindMatchHighlightMarker.attribute] != nil {
                selected[.backgroundColor] = attributes[EditorFindMatchHighlightMarker.coveredBackgroundAttribute]
            }
            syntax.addAttributes(selected, range: range)
        }
        return syntax
    }
}

struct ReconciledHostedPresentation: Equatable {
    let syntax: NSAttributedString
    let foldedRanges: IndexSet
    let imageMarkerRanges: IndexSet
    let imageVisualStates: [WYSIWYGImagePresentationMarker.VisualState]
}

private final class ReconciledPublicationInterception {
    var proposedSource: String?
}
