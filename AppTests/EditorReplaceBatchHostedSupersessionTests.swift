import AppKit
@testable import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import XCTest

@MainActor
extension EditorFindHostedGateTests {
    func testHostedReplaceAllQueryABAWhilePreparingDropsPlanWithoutUndo() async throws {
        try await assertHeldHostedBatchSupersession { hosted in
            hosted.appState.handleEditorFindQueryTextChange("one")
            hosted.appState.handleEditorFindQueryTextChange("hit")
            try await self.waitUntil("returned query has a fresh retained set") {
                hosted.appState.editorFindHost.controller.session?.query.pattern == "hit"
            }
        }
    }

    func testHostedReplaceAllOptionsABAWhilePreparingDropsPlanWithoutUndo() async throws {
        try await assertHeldHostedBatchSupersession { hosted in
            hosted.appState.setEditorFindMatchCase(true)
            hosted.appState.setEditorFindMatchCase(false)
            try await self.waitUntil("returned options have a fresh retained set") {
                hosted.appState.editorFindHost.controller.session != nil
            }
        }
    }

    func testHostedReplaceAllReplacementABAWhilePreparingDropsPlanWithoutUndo() async throws {
        try await assertHeldHostedBatchSupersession { hosted in
            hosted.appState.setEditorReplaceReplacement("OTHER")
            hosted.appState.setEditorReplaceReplacement("NEW")
        }
    }

    func testHostedReplaceAllEditWhilePreparingCannotApplyOldSourcePlan() async throws {
        try await assertHeldHostedBatchSupersession { hosted in
            let editor = try self.hostedEditor(hosted)
            let length = (hosted.appState.currentDocument.text as NSString).length
            editor.insertText("!", replacementRange: NSRange(location: length, length: 0))
            try await self.waitUntil("ordinary typing is authoritative and rescanned") {
                hosted.appState.currentDocument.text == "hit one hit two!"
                    && hosted.appState.editorFindHost.controller.session != nil
            }
        }
    }

    func testHostedReplaceAllRebindWhilePreparingDropsPlanWithoutUndo() async throws {
        try await assertHeldHostedBatchSupersession { hosted in
            // A same-identity lifecycle rebind still advances App's monotonic fence.
            hosted.appState.notifyEditorFindDocumentIdentityDidRekey()
            try await self.waitUntil("rebound retained set is available") {
                hosted.appState.editorFindHost.controller.session != nil
            }
        }
    }

    func testHostedReplaceAllFindNavigationWhilePreparingDropsPlanWithoutUndo() async throws {
        try await assertHeldHostedBatchSupersession { hosted in
            hosted.appState.stepEditorFindFromBarControl(.next)
            try await self.waitUntil("explicit Find navigation applies to the second match") {
                self.appliedRange(in: hosted.window) == NSRange(location: 8, length: 3)
            }
        }
    }

    func testHostedReplaceAllNativeSelectionABAWhilePreparingDropsPlanWithoutUndo() async throws {
        try await assertHeldHostedBatchSupersession { hosted in
            let editor = try self.hostedEditor(hosted)
            let original = editor.selectedRange()
            editor.textSelection = NSRange(location: 4, length: 0)
            editor.textSelection = original
            XCTAssertEqual(editor.selectedRange(), original)
        }
    }

    func testHostedReplaceAllKeyWindowABAWhilePreparingDropsPlanWithoutUndo() async throws {
        try await assertHeldHostedBatchSupersession { hosted in
            self.designateKeyWindow(nil, in: hosted.group)
            self.designateKeyWindow(hosted.window, in: hosted.group)
        }
    }

    func testHostedReplaceAllEditorRemountWhilePreparingDropsPlanWithoutUndo() async throws {
        try await assertHeldHostedBatchSupersession { hosted in
            let original = self.editorCoordinator(in: hosted.window)
            let installation = try XCTUnwrap(original?.currentDocumentBindingInstallation)
            // Exercise the real App installation authority: release/reinstall of the
            // originating editor, rather than merely inventing a different stamp.
            let binding = hosted.appState.editorDocumentBinding(for: hosted.appState.currentDocument)
            binding.onLifecycle(.revoked(installation))
            binding.onLifecycle(.installed(installation))
        }
    }

    func testHostedReplaceAllWorkspaceSearchFocusWhilePreparingDropsPlanWithoutUndo() async throws {
        try await assertHeldHostedBatchSupersession { hosted in
            hosted.appState.focusWorkspaceSearch()
        }
    }

    func testHostedReplaceAllRepeatedWorkspaceSearchFocusAfterFindFocusSupersededDropsPlan() async throws {
        let hosted = try await makeHostedBatchWorkspace()
        let app = hosted.appState
        app.editorFindHost.commandContextOverride = nil
        app.supersedePendingEditorFindFocus()
        let (hold, task) = try await startHeldHostedBatch(hosted)
        defer { hold.release() }
        let before = try EditorReplaceEffectSnapshot(app, textView: hostedEditor(hosted))
        let generation = app.editorReplaceAuthorityGeneration
        app.focusWorkspaceSearch()
        XCTAssertGreaterThan(app.editorReplaceAuthorityGeneration, generation)
        hold.release()
        let result = await task.value
        XCTAssertEqual(result, .superseded)
        try assertHostedBatchDidNotWrite(hosted, since: before)
    }

    func testHostedReplaceAllWorkspaceSearchActivationWhilePreparingDropsPlanWithoutUndo() async throws {
        try await assertHeldHostedBatchSupersession { hosted in
            hosted.appState.notifyEditorFindWorkspaceSearchWillNavigate(to: NSRange(location: 4, length: 3))
            try await self.waitUntil("workspace activation counter-only recomputation drains") {
                hosted.appState.editorFindHost.controller.session != nil
            }
        }
    }

    func testHostedReplaceAllBarCloseWhilePreparingDropsPlanWithoutUndo() async throws {
        try await assertHeldHostedBatchSupersession { hosted in hosted.appState.closeEditorFindBar() }
    }

    func testHostedReplaceAllCollapseLifecycleWhilePreparingDropsPlanWithoutUndo() async throws {
        try await assertHeldHostedBatchSupersession { hosted in
            // The replacement disclosure arrives in PR H. This is the existing
            // lifecycle-generation seam H must call when the row collapses.
            hosted.appState.advanceEditorReplaceAuthorityGeneration()
        }
    }

    func testHostedReplaceAllCancelWhilePreparingLeavesExactSourceSelectionOrdinalAndUndo() async throws {
        let source = "**hit** ![image](fixture.png) hit **untouched**"
        let hosted = try await makeHostedBatchWorkspace(source: source, layoutMode: .wysiwyg)
        let editor = try hostedEditor(hosted)
        editor.textSelection = NSRange(location: source.utf16.count, length: 0)
        try await waitForHostedBatchPresentationQuiescence(hosted)
        let (hold, task) = try await startHeldHostedBatch(hosted)
        defer { hold.release() }
        let before = EditorReplaceEffectSnapshot(hosted.appState, textView: editor)
        XCTAssertFalse(before.foldedRanges.isEmpty)
        XCTAssertFalse(before.imageMarkerRanges.isEmpty)
        hosted.appState.cancelEditorReplaceAll()
        let began = Date()
        hold.release()
        let result = await task.value
        print("Replace All informational Cancel-to-drain: \(Date().timeIntervalSince(began) * 1000) ms")
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(EditorReplaceEffectSnapshot(hosted.appState, textView: editor), before)
        XCTAssertFalse(hosted.appState.editorFindHost.replaceBatch.isPreparing)
    }

    func testHostedReplaceAllCallerTaskCancellationDrainsWithoutMutation() async throws {
        let hosted = try await makeHostedBatchWorkspace()
        let (hold, task) = try await startHeldHostedBatch(hosted)
        defer { hold.release() }
        let before = try EditorReplaceEffectSnapshot(hosted.appState, textView: hostedEditor(hosted))
        task.cancel()
        hold.release()
        let result = await task.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(try EditorReplaceEffectSnapshot(hosted.appState, textView: hostedEditor(hosted)), before)
        XCTAssertFalse(hosted.appState.editorFindHost.replaceBatch.isPreparing)
    }

    func testHostedReplaceAllNewFenceABADuringPreparationDropsPlanWithoutUndo() async throws {
        try await assertHeldHostedBatchSupersession { hosted in
            let identity = ObjectIdentifier(hosted.appState.currentDocument)
            hosted.appState.workspaceMutationWriteFences.insert(identity)
            hosted.appState.workspaceMutationWriteFences.remove(identity)
            XCTAssertEqual(
                hosted.appState.editorReplaceAuthorizationDecision(for: hosted.appState.currentDocument),
                .allowed
            )
        }
    }

    private func assertHeldHostedBatchSupersession(
        _ steer: @escaping @MainActor (HostedReplaceWorkspace) async throws -> Void
    ) async throws {
        let hosted = try await makeHostedBatchWorkspace()
        let (hold, task) = try await startHeldHostedBatch(hosted)
        defer { hold.release() }
        let schedules = hosted.appState.editorFindHost.controller.replacementScheduleCount
        try await steer(hosted)
        // Let the steering event's ordinary SwiftUI/native effects settle first.
        await Task.yield()
        let editor = try hostedEditor(hosted)
        let before = EditorReplaceEffectSnapshot(hosted.appState, textView: editor)
        hold.release()
        let result = await task.value
        assertHostedBatchSuperseded(result)
        try assertHostedBatchDidNotWrite(hosted, since: before)
        XCTAssertEqual(editor.selectedRange(), before.selection)
        XCTAssertEqual(hosted.appState.editorFindHost.controller.replacementScheduleCount, schedules)
        XCTAssertFalse(hosted.appState.editorFindHost.replaceBatch.isPreparing)
    }
}
