import AppKit
@testable import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import XCTest

/// Keep Mine resolves a real external conflict by re-adopting the unchanged local source.
/// The editor already shows exactly that source, so it must keep its presentation: folds,
/// link folding, image markers, syntax attributes and Find decoration. Reload with different
/// text still installs the disk source and re-derives presentation through the normal path.
@MainActor
extension EditorFindHostedGateTests {
    func testHostedKeepMineInWYSIWYGRetainsFoldsImageMarkersAndFindDecorationWithoutAnEdit() async throws {
        let base = "Intro **one** and *two* [docs](https://host/a%2Fb) ![alt](fixture.png) tail"
        let local = base + " local"
        let hosted = try await makeHostedEditorWorkspace(
            source: base,
            query: "one",
            localEdit: local,
            assets: ["fixture.png": reconciledFixturePNG()],
            layoutMode: .wysiwyg
        )
        let editor = try hostedEditor(hosted)
        let storage = try XCTUnwrap(MarkdownTextView.textStorage(of: editor))
        let coordinator = try XCTUnwrap(editor.textDelegate as? MarkdownTextViewCoordinator)
        try await waitUntil("the local source shows folds and a ready image thumbnail") {
            storage.string == local && self.hasFoldsAndReadyImage(self.reconciledPresentation(editor))
        }
        try await settleReconciledHighlight(coordinator)
        let match = try XCTUnwrap(hosted.appState.editorFindHost.controller.session?.currentMatch?.range)
        assertReconciledFindDecoration(in: storage, match: match)

        try await assertKeepMineRetainsPresentation(hosted, disk: base + " disk", match: match)
    }

    func testHostedKeepMineInSourceModeRetainsHighlightingWithoutAnEdit() async throws {
        let base = "# Heading\n\nIntro **one** and `code` tail"
        let local = base + " local"
        let hosted = try await makeHostedEditorWorkspace(
            source: base, query: "one", localEdit: local, layoutMode: .sourceOnly
        )
        let editor = try hostedEditor(hosted)
        let storage = try XCTUnwrap(MarkdownTextView.textStorage(of: editor))
        let coordinator = try XCTUnwrap(editor.textDelegate as? MarkdownTextViewCoordinator)
        try await waitUntil("the local source is highlighted") {
            let heading = storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
            return storage.string == local
                && (heading?.pointSize ?? 0) > MarkdownSyntaxHighlighter.defaultFont.pointSize
        }
        try await settleReconciledHighlight(coordinator)
        let match = try XCTUnwrap(hosted.appState.editorFindHost.controller.session?.currentMatch?.range)
        assertReconciledFindDecoration(in: storage, match: match)

        try await assertKeepMineRetainsPresentation(hosted, disk: base + " disk", match: match)
    }

    /// Different text takes the whole-source assignment, which clears presentation; the App text
    /// change schedules the ordinary parse, so presentation returns with no further input.
    func testHostedReloadWithChangedTextStillRederivesWYSIWYGPresentation() async throws {
        let base = "Intro **one** and *two* [docs](https://host/a%2Fb) ![alt](fixture.png) tail"
        let local = base + " local"
        let disk = "Intro **uno** and *dos* [docs](https://host/c) ![alt](fixture.png) end"
        let hosted = try await makeHostedEditorWorkspace(
            source: base,
            query: "and",
            localEdit: local,
            assets: ["fixture.png": reconciledFixturePNG()],
            layoutMode: .wysiwyg
        )
        let appState = hosted.appState
        let session = appState.currentDocument
        let editor = try hostedEditor(hosted)
        let storage = try XCTUnwrap(MarkdownTextView.textStorage(of: editor))
        let coordinator = try XCTUnwrap(editor.textDelegate as? MarkdownTextViewCoordinator)
        try await waitUntil("the local source shows folds and a ready image thumbnail") {
            storage.string == local && self.hasFoldsAndReadyImage(self.reconciledPresentation(editor))
        }
        try await settleReconciledHighlight(coordinator)
        try await recordExternalConflict(hosted, disk: disk)
        let revisionBefore = coordinator.lastAppliedHighlightRevision

        appState.reloadExternallyChangedFile()
        try await waitUntil("Reload converges and completes") {
            appState.externalChangePrompt == nil
                && appState.externalReloadTasks.isEmpty
                && appState.pendingExternalReloadApplications.isEmpty
                && session.text == disk
        }

        // Observe only: no edit, selection change or manual scheduling restores presentation.
        try await waitUntil("the disk source is parsed, folded and its image thumbnail is ready") {
            storage.string == disk
                && coordinator.lastAppliedHighlightRevision != revisionBefore
                && self.hasFoldsAndReadyImage(self.reconciledPresentation(editor))
        }
        try await settleReconciledHighlight(coordinator)
        XCTAssertEqual(storage.string, disk)
        XCTAssertEqual(session.text, disk)
        XCTAssertFalse(editor.undoManager?.canUndo == true)
        XCTAssertFalse(editor.undoManager?.canRedo == true)
        try assertReconciledPresentationMatchesFreshParse(hosted, editor: editor, coordinator: coordinator)
    }

    private func assertKeepMineRetainsPresentation(
        _ hosted: HostedReplaceWorkspace,
        disk: String,
        match: NSRange
    ) async throws {
        let appState = hosted.appState
        let session = appState.currentDocument
        let local = session.text
        let editor = try hostedEditor(hosted)
        let storage = try XCTUnwrap(MarkdownTextView.textStorage(of: editor))
        let coordinator = try XCTUnwrap(editor.textDelegate as? MarkdownTextViewCoordinator)
        try await recordExternalConflict(hosted, disk: disk)
        let before = reconciledPresentation(editor)
        let selectionBefore = editor.selectedRange()
        let revisionBefore = session.version
        let bindingBefore = coordinator.currentDocumentBindingInstallation
        let edits = StorageCharacterEditCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                if storage.editedMask.contains(.editedCharacters) { edits.count += 1 }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        appState.keepMineForExternallyChangedFile()
        try await waitUntil("Keep Mine converges and completes") {
            appState.externalChangePrompt == nil
                && appState.externalReloadTasks.isEmpty
                && appState.pendingExternalReloadApplications.isEmpty
        }

        XCTAssertEqual(session.text, local)
        XCTAssertEqual(session.version, revisionBefore)
        XCTAssertEqual(coordinator.currentDocumentBindingInstallation, bindingBefore)
        XCTAssertEqual(edits.count, 0, "the editor already shows the retained source: no native install")
        XCTAssertEqual(storage.string, local)
        XCTAssertEqual(editor.selectedRange(), selectionBefore)
        XCTAssertFalse(editor.undoManager?.canUndo == true)
        XCTAssertFalse(editor.undoManager?.canRedo == true)
        // Immediately after convergence and with no input, nothing was cleared.
        let after = reconciledPresentation(editor)
        XCTAssertEqual(after.syntax, before.syntax)
        XCTAssertEqual(after.foldedRanges, before.foldedRanges)
        XCTAssertEqual(after.imageMarkerRanges, before.imageMarkerRanges)
        XCTAssertEqual(after.imageVisualStates, before.imageVisualStates)
        assertReconciledFindDecoration(in: storage, match: match)

        // Still equal to an independent fresh parse once the scheduler is quiet.
        try await settleReconciledHighlight(coordinator)
        XCTAssertEqual(edits.count, 0)
        XCTAssertEqual(reconciledPresentation(editor), before)
        assertReconciledFindDecoration(in: storage, match: match)
        try assertReconciledPresentationMatchesFreshParse(hosted, editor: editor, coordinator: coordinator)
    }

    private func hasFoldsAndReadyImage(_ presentation: ReconciledHostedPresentation) -> Bool {
        !presentation.foldedRanges.isEmpty && presentation.imageVisualStates.contains {
            if case .ready = $0 { return true }
            return false
        }
    }
}

private final class StorageCharacterEditCounter {
    var count = 0
}
