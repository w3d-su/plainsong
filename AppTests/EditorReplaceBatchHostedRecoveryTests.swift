import AppKit
@testable import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import XCTest

@MainActor
extension EditorFindHostedGateTests {
    func testHostedReplaceAllRejectedPublicationRestoresFoldsAndImagesExactlyOnce() async throws {
        let source = "**hit** ![image](fixture.png) hit **untouched**"
        let hosted = try await makeHostedBatchWorkspace(source: source, layoutMode: .wysiwyg)
        let app = hosted.appState
        let editor = try hostedEditor(hosted)
        let coordinator = try XCTUnwrap(editor.textDelegate as? MarkdownTextViewCoordinator)
        editor.textSelection = NSRange(location: source.utf16.count, length: 0)
        try await waitForHostedBatchPresentationQuiescence(hosted)
        let before = EditorReplaceEffectSnapshot(app, textView: editor)
        let passes = try HostedBatchPresentationObservation(
            editor: editor, original: source, expected: source,
            attempted: "**NEW** ![image](fixture.png) NEW **untouched**"
        )
        defer { passes.stop() }
        let identity = ObjectIdentifier(app.currentDocument)
        let initialWriter = app.editorWriterInstallations[identity]
        let observation = BatchRejectedPublicationObservation()
        let observer = NotificationCenter.default.addObserver(
            forName: Notification.Name("NSTextWillChangeNotification"), object: editor, queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                guard coordinator.writerAuthorizedTextMutationDepth > 0 else { return }
                observation.refusedNativePublication = true
                // Removing the admitted writer makes the real App publication reject.
                app.editorWriterInstallations[identity] = nil
            }
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            app.editorWriterInstallations[identity] = initialWriter
        }
        let result = await app.performEditorReplaceAll(replacement: "NEW")
        app.editorWriterInstallations[identity] = initialWriter
        XCTAssertTrue(observation.refusedNativePublication)
        XCTAssertEqual(result, .delivered(.refused(.writeNotApplied)))
        try await waitForHostedBatchPresentationQuiescence(hosted, observation: passes)
        try assertHostedBatchDidNotWrite(hosted, since: before)
        let after = EditorReplaceEffectSnapshot(app, textView: editor)
        XCTAssertEqual(after.selection, before.selection)
        XCTAssertEqual(after.foldedRanges, before.foldedRanges)
        XCTAssertEqual(after.imageMarkerRanges, before.imageMarkerRanges)
        XCTAssertEqual(passes.suspensions, 1)
        XCTAssertEqual(passes.reapplications, 1)
    }
}

@MainActor
private final class BatchRejectedPublicationObservation {
    var refusedNativePublication = false
}
