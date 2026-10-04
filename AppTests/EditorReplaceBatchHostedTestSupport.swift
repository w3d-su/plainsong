import AppKit
@testable import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import XCTest

/// Holds only the detached preparation worker. Tests keep the main actor free to
/// exercise real App and native-editor supersession paths before releasing it.
final class HostedReplaceBatchHold: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    private var onMainThread = false

    var isEntered: Bool {
        condition.lock()
        defer { condition.unlock() }
        return entered
    }

    var didRunOnMainThread: Bool {
        condition.lock()
        defer { condition.unlock() }
        return onMainThread
    }

    func checkpoint() {
        condition.lock()
        defer { condition.unlock() }
        guard !entered else { return }
        entered = true
        onMainThread = Thread.isMainThread
        condition.broadcast()
        let deadline = Date().addingTimeInterval(20)
        while !released {
            if !condition.wait(until: deadline) {
                break
            }
        }
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

/// Observe existing TextKit attribute transactions only while the batch gate runs;
/// no production instrumentation is added to typing, selection or highlight apply.
@MainActor
final class HostedBatchPresentationObservation {
    private var observer: NSObjectProtocol?
    private(set) var suspensions = 0
    private(set) var reapplications = 0

    init(editor: MarkdownSTTextView, original: String, expected: String) throws {
        let storage = try XCTUnwrap(MarkdownTextView.textStorage(of: editor))
        observer = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil
        ) { [weak self, weak storage] _ in
            MainActor.assumeIsolated {
                guard let observation = self, let storage else { return }
                XCTAssertTrue(ExactSourceText.matches(storage.string, original)
                    || ExactSourceText.matches(storage.string, expected), "backing text stays canonical throughout")
                guard storage.editedMask == .editedAttributes,
                      storage.editedRange == NSRange(location: 0, length: storage.length)
                else { return }
                var hasFold = false
                storage.enumerateAttribute(WYSIWYGInlineFoldPresentation.foldedDelimiterAttribute,
                                           in: NSRange(location: 0, length: storage.length))
                { value, _, _ in
                    if value != nil {
                        hasFold = true
                    }
                }
                if ExactSourceText.matches(storage.string, original), !hasFold {
                    observation.suspensions += 1
                } else if ExactSourceText.matches(storage.string, expected), hasFold {
                    observation.reapplications += 1
                }
            }
        }
    }

    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
    }
}

@MainActor
extension EditorFindHostedGateTests {
    func makeHostedBatchWorkspace(
        source: String = "hit one hit two",
        query: String = "hit",
        layoutMode: EditorLayoutMode = .sourceOnly
    ) async throws -> HostedReplaceWorkspace {
        let hosted = try await makeHostedEditorWorkspace(source: source, query: query, layoutMode: layoutMode)
        try await waitUntil("batch fixture has current source and settled authorization", timeout: 20) {
            let app = hosted.appState
            let editor = self.editorTextView(in: hosted.window)
            return app.editorReplaceAuthorizationDecision(for: app.currentDocument) == .allowed
                && editor?.text == app.currentDocument.text
                && app.editorFindHost.controller.documentBinding.revision == UInt64(app.currentDocument.version)
        }
        // Fixture observation is already drained by the common Replace setup. Stop
        // subsequent filesystem notifications so only the tested event can supersede.
        hosted.appState.workspaceWatcher?.stop()
        return hosted
    }

    func startHeldHostedBatch(
        _ hosted: HostedReplaceWorkspace,
        replacement: String = "NEW",
        atCheckpoint: @escaping @Sendable (EditorReplacePreparationChunk) -> Bool = { _ in true }
    ) async throws -> (HostedReplaceBatchHold, Task<EditorReplaceBatchCommandResult, Never>) {
        let hold = HostedReplaceBatchHold()
        hosted.appState.editorFindHost.replaceBatch.onChunkForTesting = { chunk in
            if atCheckpoint(chunk) {
                hold.checkpoint()
            }
        }
        addTeardownBlock { @MainActor in
            hold.release()
            hosted.appState.editorFindHost.replaceBatch.onChunkForTesting = nil
        }
        let task = Task { @MainActor in
            await hosted.appState.performEditorReplaceAll(replacement: replacement)
        }
        try await waitUntil("detached batch preparation reaches the held checkpoint") { hold.isEntered }
        XCTAssertFalse(hold.didRunOnMainThread, "source construction must run off the main actor")
        return (hold, task)
    }

    /// Compare only mutation effects. Query/navigation/fence steering may itself
    /// legitimately change Find/recovery state; the discarded plan must add no write.
    func assertHostedBatchDidNotWrite(
        _ hosted: HostedReplaceWorkspace,
        since before: EditorReplaceEffectSnapshot,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let after = try EditorReplaceEffectSnapshot(hosted.appState, textView: hostedEditor(hosted))
        XCTAssertEqual(after.appText, before.appText, file: file, line: line)
        XCTAssertEqual(after.appVersion, before.appVersion, file: file, line: line)
        XCTAssertEqual(after.isDirty, before.isDirty, file: file, line: line)
        XCTAssertEqual(after.viewText, before.viewText, file: file, line: line)
        XCTAssertEqual(after.canUndo, before.canUndo, file: file, line: line)
        XCTAssertEqual(after.canRedo, before.canRedo, file: file, line: line)
    }

    func assertHostedBatchSuperseded(
        _ result: EditorReplaceBatchCommandResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(result, .superseded, file: file, line: line)
    }

    func assertHostedBatchRawSource(
        _ editor: MarkdownSTTextView,
        source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(MarkdownTextView.textStorage(of: editor)?.string, source, file: file, line: line)
        XCTAssertEqual(editor.accessibilityValue() as? String, source, file: file, line: line)
        let selection = editor.selectedRange()
        let length = (source as NSString).length
        guard selection.location <= length, selection.length <= length - selection.location else {
            return XCTFail("selection must address raw UTF-16 source", file: file, line: line)
        }
        let selected = (source as NSString).substring(with: selection)
        XCTAssertEqual(editor.accessibilitySelectedText(), selected, file: file, line: line)
        if selection.length > 0 {
            let board = NSPasteboard(name: NSPasteboard.Name("ReplaceBatch-\(UUID().uuidString)"))
            XCTAssertTrue(editor.writeSelection(to: board, types: [.string]), file: file, line: line)
            XCTAssertEqual(board.string(forType: .string), selected, file: file, line: line)
        }
    }
}
