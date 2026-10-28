@testable import PlainsongIOSM0
import UIKit
import XCTest

final class RollbackBaselineTests: XCTestCase {
    @MainActor
    func testReopenedOriginalChangedWhileClosedPreservesEditorAndFencesWrites() async throws {
        try await assertRollbackConflict(baseline: "original source 繁中", changed: "new provider source")
    }

    @MainActor
    func testReopenedOriginalCanonicalEquivalentBytesStillConflict() async throws {
        let baseline = "original caf\u{E9}"
        let changed = "original cafe\u{301}"
        XCTAssertEqual(baseline, changed)
        XCTAssertFalse(sameSource(baseline, changed))
        try await assertRollbackConflict(baseline: baseline, changed: changed)
    }

    @MainActor
    func testRollbackRecoveryFailureKeepsConflictFenceAndFailureVisible() async throws {
        try await assertRollbackConflict(
            baseline: "original retained source", changed: "external provider source", recoveryFails: true
        )
    }

    @MainActor
    private func assertRollbackConflict(baseline: String, changed: String, recoveryFails: Bool = false) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("original.md")
        let second = directory.appendingPathComponent("candidate.md")
        try Data(baseline.utf8).write(to: first)
        try Data("candidate source".utf8).write(to: second)
        var staged: SpikeDocument?
        var recoveries: [RecoveryEnvelope] = []
        let editor = SourceEditor()
        let session = DocumentSession(editor: editor, probe: Probe(), makeDocument: { url in
            let document = SpikeDocument(fileURL: url)
            if url == second {
                staged = document
            }
            return document
        }, closeForReplacement: { document in
            let closed: Bool = await withCheckedContinuation { continuation in
                document.close { continuation.resume(returning: $0) }
            }
            guard closed, let staged else {
                XCTFail("The real original document must close before its provider changes")
                return false
            }
            let reverted: Bool = await withCheckedContinuation { continuation in
                staged.revert(toContentsOf: second) { continuation.resume(returning: $0) }
            }
            XCTAssertFalse(reverted)
            do {
                try Data(changed.utf8).write(to: first)
            } catch {
                XCTFail("Could not simulate the original provider change: \(error)")
                return false
            }
            return true
        }, persistRecovery: { recovery in
            if recoveryFails {
                throw CocoaError(.fileWriteNoPermission)
            }
            recoveries.append(recovery)
        })
        let originalGrant = try AccessGrant(root: first, scope: .singleFile, appPrivate: true)
        await session.open(url: first, grant: originalGrant)
        let original = try XCTUnwrap(session.document)
        let identity = editor.documentID
        let revision = editor.revision
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        controller.view = editor.textView
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        editor.textView.becomeFirstResponder()
        editor.textView.selectedRange = NSRange(location: 2, length: 4)
        let selection = editor.textView.selectedRange
        let undo = try XCTUnwrap(editor.textView.undoManager)
        let marker = RollbackUndoMarker()
        undo.beginUndoGrouping()
        undo.registerUndo(withTarget: marker) { $0.didUndo = true }
        undo.endUndoGrouping()
        XCTAssertTrue(undo.canUndo)
        let canRedo = undo.canRedo

        try await session.open(url: second, grant: AccessGrant(root: second, scope: .singleFile, appPrivate: true))

        XCTAssertTrue(session.document === original)
        XCTAssertTrue(session.grant === originalGrant)
        XCTAssertFalse(original.documentState.contains(.closed))
        XCTAssertTrue(try XCTUnwrap(staged).documentState.contains(.closed))
        XCTAssertTrue(sameSource(original.loadedSource, changed))
        XCTAssertTrue(sameSource(editor.textView.text, baseline))
        XCTAssertEqual(editor.documentID, identity)
        XCTAssertEqual(editor.revision, revision)
        XCTAssertEqual(editor.textView.selectedRange, selection)
        XCTAssertTrue(undo.canUndo)
        XCTAssertEqual(undo.canRedo, canRedo)
        undo.undo()
        XCTAssertTrue(marker.didUndo)
        XCTAssertTrue(sameSource(editor.textView.text, baseline))
        XCTAssertFalse(session.dirty)
        XCTAssertTrue(session.conflict)
        XCTAssertEqual(session.ledger?.available, false)
        XCTAssertTrue(try sameSource(XCTUnwrap(session.ledger).savedSource, baseline))
        XCTAssertFalse(editor.textView.isEditable)
        if recoveryFails {
            XCTAssertTrue(session.message.contains("Recovery write/readback failed"))
            XCTAssertTrue(session.message.contains("do not terminate"))
            XCTAssertTrue(recoveries.isEmpty)
            XCTAssertTrue(session.probe.events.contains { $0.event == "recovery-failed" })
        } else {
            XCTAssertTrue(session.message.contains("Original changed while closed"))
            let recovery = try XCTUnwrap(recoveries.last)
            XCTAssertEqual(recovery.reason, "rollback-external-conflict")
            XCTAssertEqual(recovery.documentID, identity)
            XCTAssertEqual(recovery.revision, revision)
            XCTAssertTrue(sameSource(recovery.source, baseline))
        }

        let enabled = expectation(description: "late original enable-editing callback delivered")
        let editingAvailability = original.editingAvailability
        original.editingAvailability = { value in
            editingAvailability?(value)
            if value {
                enabled.fulfill()
            }
        }
        original.enableEditing()
        await fulfillment(of: [enabled], timeout: 5)
        original.editingAvailability = editingAvailability
        XCTAssertFalse(editor.textView.isEditable)
        let saved: Bool = await withCheckedContinuation { continuation in
            session.save { continuation.resume(returning: $0) }
        }
        XCTAssertFalse(saved)
        XCTAssertEqual(try Data(contentsOf: first), Data(changed.utf8))
        let closed: Bool = await withCheckedContinuation { continuation in
            original.close { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(closed)
    }
}

private final class RollbackUndoMarker: NSObject {
    var didUndo = false
}
