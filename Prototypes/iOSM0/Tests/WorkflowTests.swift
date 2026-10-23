@testable import PlainsongIOSM0
import UIKit
import XCTest

final class WorkflowTests: XCTestCase {
    @MainActor
    func testFixtureButtonOpensEditableBundledBytesInAppPrivateDocument() async throws {
        let host = try WorkflowHost()
        defer { host.hide() }
        do {
            let fixture = try XCTUnwrap(Bundle.main.url(forResource: "m0", withExtension: "md"))
            let expected = try Data(contentsOf: fixture)
            XCTAssertFalse(expected.isEmpty)
            let button: UIButton = try host.control("m0-fixture")
            button.sendActions(for: .touchUpInside)
            let waitStarted = Date()
            do {
                try await waitUntil(timeout: 6) {
                    host.session.document != nil && !host.session.opening && host.session.editor.textView.isEditable
                }
            } catch WorkflowFailure.timeout {
                // Capture before cleanup changes the document state. Avoid a UIKit snapshot here:
                // rendering could stall and obscure when the readiness deadline actually expired.
                attachFixtureTimeout(session: host.session, elapsed: Date().timeIntervalSince(waitStarted))
                throw WorkflowFailure.timeout
            }
            let document = try XCTUnwrap(host.session.document)
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            XCTAssertEqual(document.fileURL.deletingLastPathComponent().standardizedFileURL,
                           directory.standardizedFileURL)
            XCTAssertNotEqual(document.fileURL, fixture)
            XCTAssertEqual(document.fileURL.pathExtension, "md")
            XCTAssertEqual(host.session.grant?.root, document.fileURL)
            XCTAssertEqual(host.session.grant?.scope, .singleFile)
            XCTAssertFalse(document.documentState.contains(.closed))
            XCTAssertTrue(host.session.editor.textView.isEditable)
            XCTAssertEqual(try Data(contentsOf: document.fileURL), expected)
            XCTAssertEqual(Data(host.session.editor.textView.text.utf8), expected)
            XCTAssertFalse(host.session.dirty)
            attachScreenshot(of: host.window, name: "Fixture opens editable bundled Markdown")
        } catch {
            await closeSession(host.session, removeDocument: true)
            throw error
        }
        await closeSession(host.session, removeDocument: true)
    }

    @MainActor
    func testDelayHelpSurvivesReportsAndTogglePreservesNativeComposition() throws {
        let host = try WorkflowHost()
        defer { host.hide() }
        let editor = host.session.editor
        XCTAssertTrue(editor.attach("# 中文 👩🏽‍💻"))
        editor.textView.isEditable = true
        let button: UIButton = try host.control("m0-delay")
        let help: UILabel = try host.control("m0-delay-help")
        XCTAssertEqual(button.title(for: .normal), "3秒：關")
        button.sendActions(for: .touchUpInside)
        XCTAssertTrue(host.session.delaySave)
        XCTAssertEqual(editor.delayNanoseconds, 3_000_000_000)
        XCTAssertEqual(button.title(for: .normal), "3秒：開")
        let instructions = try XCTUnwrap(help.text)
        XCTAssertFalse(instructions.isEmpty)
        XCTAssertFalse(help.isHidden)
        XCTAssertGreaterThan(help.alpha, 0)
        host.session.report("An unrelated save/status event", event: "workflow-test-report")
        XCTAssertEqual(help.text, instructions, "Status reports must not erase the inline test instructions.")
        XCTAssertNil(host.controller.presentedViewController)
        let fullFrame = host.window.frame
        let layoutSource = Data(editor.textView.text.utf8)
        // Model a compact content area; this is not a physical keyboard acceptance test.
        host.window.frame = CGRect(origin: fullFrame.origin, size: CGSize(width: 393, height: 390))
        host.window.layoutIfNeeded()
        let controls: UIScrollView = try host.control("m0-controls")
        XCTAssertGreaterThan(editor.textView.bounds.height, 80,
                             "Inline guidance must leave a usable editor in a compact content area.")
        XCTAssertGreaterThan(editor.textView.bounds.width, 200)
        XCTAssertGreaterThan(controls.contentSize.height, controls.bounds.height,
                             "Instructions must scroll when the compact control area overflows.")
        controls.scrollRectToVisible(help.convert(help.bounds, to: controls), animated: false)
        XCTAssertEqual(Data(editor.textView.text.utf8), layoutSource)
        attachScreenshot(of: host.window, name: "Three-second delay inline instructions, compact content area")
        host.window.frame = fullFrame
        host.window.layoutIfNeeded()

        XCTAssertTrue(editor.textView.becomeFirstResponder())
        editor.textView.selectedRange = NSRange(location: editor.textView.text.utf16.count, length: 0)
        editor.textView.setMarkedText("ㄓㄨ", selectedRange: NSRange(location: 2, length: 0))
        let marked = try XCTUnwrap(editor.textView.markedTextRange)
        let source = Data(editor.textView.text.utf8)
        let selection = editor.textView.selectedRange
        let markedRange = textRange(marked, in: editor.textView)
        let revision = editor.revision
        let canUndo = editor.textView.undoManager?.canUndo
        let canRedo = editor.textView.undoManager?.canRedo
        defer { editor.textView.unmarkText() }
        for expectedOn in [false, true] {
            button.sendActions(for: .touchUpInside)
            XCTAssertEqual(host.session.delaySave, expectedOn)
            XCTAssertEqual(editor.delayNanoseconds, expectedOn ? 3_000_000_000 : 150_000_000)
            XCTAssertEqual(button.title(for: .normal), expectedOn ? "3秒：開" : "3秒：關")
            XCTAssertEqual(Data(editor.textView.text.utf8), source)
            XCTAssertEqual(editor.textView.selectedRange, selection)
            XCTAssertEqual(editor.revision, revision)
            XCTAssertEqual(textRange(try XCTUnwrap(editor.textView.markedTextRange), in: editor.textView), markedRange)
            XCTAssertEqual(editor.textView.undoManager?.canUndo, canUndo)
            XCTAssertEqual(editor.textView.undoManager?.canRedo, canRedo)
            XCTAssertNil(host.controller.presentedViewController, "Delay must not present a modal during composition.")
        }
        host.session.report("Another unrelated status", event: "workflow-test-report-after-toggle")
        XCTAssertEqual(help.text, instructions)
    }

    @MainActor
    func testDelayedDocumentSessionSavesCapturedRevisionBeforeLaterNativeEdit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("delayed-unicode.md")
        let baseline = "# 基準 e\u{301} 👩🏽‍💻\n"
        try Data(baseline.utf8).write(to: url)
        let host = try WorkflowHost()
        defer { host.hide() }
        let session = host.session
        let editor = session.editor
        do {
            let grant = try AccessGrant(root: url, scope: .singleFile, appPrivate: true)
            await session.open(url: url, grant: grant)
            XCTAssertEqual(session.document?.fileURL, url)
            XCTAssertTrue(editor.textView.isEditable)
            XCTAssertTrue(editor.textView.becomeFirstResponder())
            let delay: UIButton = try host.control("m0-delay")
            delay.sendActions(for: .touchUpInside)
            XCTAssertTrue(session.delaySave)
            appendNative("A", to: editor)
            let sourceN = Data(editor.textView.text.utf8)
            let revisionN = editor.revision
            let state = SaveWorkflowState()
            let start = Date()
            session.save { success in
                state.firstCompleted = true
                XCTAssertTrue(success)
                // Assert inside the acknowledgement, before another autosave can advance the disk.
                XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 2.8)
                XCTAssertEqual(try? Data(contentsOf: url), sourceN)
                XCTAssertEqual(Data(editor.textView.text.utf8), state.sourceNPlusOne)
                XCTAssertEqual(editor.revision, state.revisionNPlusOne)
                XCTAssertEqual(editor.textView.selectedRange, state.selectionNPlusOne)
                XCTAssertEqual(session.ledger.map { Data($0.savedSource.utf8) }, sourceN)
                XCTAssertTrue(session.dirty, "Acknowledging N must leave N+1 dirty.")
                XCTAssertFalse(session.saving)
                guard success else { state.finished = true; return }
                state.secondStarted = Date()
                // Capture N+1 without yielding to UIDocument's automatic save scheduling.
                session.save { secondSuccess in
                    state.secondCompleted = true
                    XCTAssertTrue(secondSuccess)
                    XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(state.secondStarted), 2.8)
                    XCTAssertEqual(try? Data(contentsOf: url), state.sourceNPlusOne)
                    XCTAssertEqual(Data(editor.textView.text.utf8), state.sourceNPlusOne)
                    XCTAssertEqual(editor.revision, state.revisionNPlusOne)
                    XCTAssertEqual(editor.textView.selectedRange, state.selectionNPlusOne)
                    XCTAssertFalse(session.dirty)
                    XCTAssertFalse(session.saving)
                    state.finished = true
                }
            }
            // save() captures synchronously; edit again before the delayed task can run.
            XCTAssertTrue(session.saving)
            XCTAssertEqual(session.ledger?.active?.revision, revisionN)
            XCTAssertEqual(session.ledger?.active.map { Data($0.source.utf8) }, sourceN)
            XCTAssertEqual(try Data(contentsOf: url), Data(baseline.utf8))
            appendNative("B", to: editor)
            state.sourceNPlusOne = Data(editor.textView.text.utf8)
            state.revisionNPlusOne = editor.revision
            state.selectionNPlusOne = editor.textView.selectedRange
            XCTAssertEqual(state.sourceNPlusOne, Data((baseline + "AB").utf8))
            XCTAssertGreaterThan(state.revisionNPlusOne, revisionN)
            try await waitUntil(timeout: 12) { state.finished }
            XCTAssertTrue(state.firstCompleted)
            XCTAssertTrue(state.secondCompleted)
        } catch {
            if await closeSession(session, removeDocument: false) {
                try? FileManager.default.removeItem(at: directory)
            }
            throw error
        }
        if await closeSession(session, removeDocument: false) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    @MainActor
    private func appendNative(_ text: String, to editor: SourceEditor) {
        editor.textView.selectedRange = NSRange(location: editor.textView.text.utf16.count, length: 0)
        editor.textView.insertText(text)
        // Programmatic UITextInput delivery is not guaranteed to invoke its delegate in every host.
        // SourceEditor deduplicates the same bytes if UIKit already delivered textViewDidChange.
        editor.textViewDidChange(editor.textView)
    }

    @MainActor
    private func textRange(_ range: UITextRange, in textView: UITextView) -> NSRange {
        NSRange(location: textView.offset(from: textView.beginningOfDocument, to: range.start),
                length: textView.offset(from: range.start, to: range.end))
    }

    @MainActor
    private func attachScreenshot(of window: UIWindow, name: String) {
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func attachFixtureTimeout(session: DocumentSession, elapsed: TimeInterval) {
        let editor = session.editor
        let marked = editor.textView.markedTextRange.map { textRange($0, in: editor.textView) }
        let snapshot = FixtureTimeoutDiagnostic(
            capturedAt: Date(), elapsedSeconds: elapsed, message: session.message,
            opening: session.opening, documentPresent: session.document != nil,
            documentStateRawValue: session.document?.documentState.rawValue,
            ledgerAvailable: session.ledger?.available, ledgerConflict: session.ledger?.conflict,
            dirty: session.dirty, saving: session.saving, editable: editor.textView.isEditable,
            markedUTF16: marked.map { [$0.location, $0.length] },
            events: session.probe.events
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let payload = (try? encoder.encode(snapshot)).map { String(decoding: $0, as: UTF8.self) }
            ?? "Fixture readiness timeout diagnostics could not be encoded."
        let attachment = XCTAttachment(string: payload)
        attachment.name = "Fixture readiness timeout state and redacted probe events"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval, _ predicate: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            guard Date() < deadline else {
                XCTFail("Workflow did not complete within \(timeout) seconds.")
                throw WorkflowFailure.timeout
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @MainActor
    @discardableResult
    private func closeSession(_ session: DocumentSession, removeDocument: Bool) async -> Bool {
        do {
            try await waitUntil(timeout: 4) { !session.saving && !session.opening }
            guard let document = session.document else { return true }
            let state = CloseWorkflowState()
            // Test assertions are complete; closing must not start another delayed autosave.
            document.requestAutosave = { $0(true) }
            document.close { success in
                Task { @MainActor in state.success = success }
            }
            try await waitUntil(timeout: 4) { state.success != nil }
            guard state.success == true else {
                XCTFail("UIDocument close failed; preserving test document and recovery evidence.")
                return false
            }
            session.grant?.release()
            if removeDocument { try FileManager.default.removeItem(at: document.fileURL) }
            let store = try RecoveryStore.applicationStore()
            let recovery = store.directory.appendingPathComponent("\(session.editor.documentID).json")
            if FileManager.default.fileExists(atPath: recovery.path) {
                try FileManager.default.removeItem(at: recovery)
            }
            return true
        } catch {
            XCTFail("Cleanup failed; preserving test document and recovery evidence: \(error)")
            return false
        }
    }
}

private enum WorkflowFailure: Error { case timeout }

// Existing ProbeEvent payloads contain hashes/ranges only: never source, URLs or bookmarks.
private struct FixtureTimeoutDiagnostic: Encodable {
    let capturedAt: Date
    let elapsedSeconds: TimeInterval
    let message: String
    let opening: Bool
    let documentPresent: Bool
    let documentStateRawValue: UInt?
    let ledgerAvailable: Bool?
    let ledgerConflict: Bool?
    let dirty: Bool
    let saving: Bool
    let editable: Bool
    let markedUTF16: [Int]?
    let events: [ProbeEvent]
}

@MainActor
private final class SaveWorkflowState {
    var firstCompleted = false
    var secondCompleted = false
    var finished = false
    var sourceNPlusOne = Data()
    var revisionNPlusOne = -1
    var selectionNPlusOne = NSRange(location: NSNotFound, length: 0)
    var secondStarted = Date.distantFuture
}

@MainActor
private final class CloseWorkflowState {
    var success: Bool?
}

@MainActor
private final class WorkflowHost {
    let controller = SpikeViewController()
    let window: UIWindow
    private weak var previousKeyWindow: UIWindow?
    var session: DocumentSession { controller.session }

    init() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.loadViewIfNeeded()
        window.layoutIfNeeded()
    }

    func control<T: UIView>(_ identifier: String) throws -> T {
        try XCTUnwrap(descendant(in: controller.view, identifier: identifier) as? T)
    }

    private func descendant(in view: UIView, identifier: String) -> UIView? {
        if view.accessibilityIdentifier == identifier { return view }
        for child in view.subviews {
            if let found = descendant(in: child, identifier: identifier) { return found }
        }
        return nil
    }

    func hide() {
        controller.view.endEditing(true)
        window.isHidden = true
        window.rootViewController = nil
        previousKeyWindow?.makeKey()
    }
}
