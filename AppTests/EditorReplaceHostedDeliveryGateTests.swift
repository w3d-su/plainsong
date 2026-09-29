import AppKit
@testable import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import XCTest

/// R7 delivery and supersession on the production `WorkspaceWindow`: Replace goes through
/// App validation, the plain EditorKit command path, key-window and installation proof,
/// and App's commit-time check — never through `performSingleReplace` directly.
@MainActor
extension EditorFindHostedGateTests {
    func testHostedReplaceChecksAuthorizationAtValidationAndAgainAtCommit() async throws {
        let hosted = try await makeHostedReplaceWorkspace(source: "hit one hit two", query: "hit")
        let appState = hosted.appState
        let editor = try hostedEditor(hosted)

        let result = appState.performEditorReplace(replacement: "HIT")

        guard case .delivered(.replaced) = result else {
            return XCTFail("Expected the key-window editor to replace, got \(result)")
        }
        XCTAssertEqual(
            appState.editorFindHost.replaceAuthority.lastAuthorizationRecord?.checkpoints,
            [.validation, .commit]
        )
        // The synchronous call returned only after the commit check, writer activation, and
        // native insert: the App source already holds the replacement.
        XCTAssertEqual(appState.currentDocument.text, "HIT one hit two")
        XCTAssertEqual(MarkdownTextView.textStorage(of: editor)?.string, "HIT one hit two")
        XCTAssertTrue(editor.undoManager?.canUndo == true)
    }

    /// A fence that appears between command validation and EditorKit's commit-time call is
    /// seen by the commit check, which refuses before writer preflight and any undo group.
    func testHostedFenceAppearingBeforeCommitRefusesAtTheCommitCheck() async throws {
        let hosted = try await makeHostedReplaceWorkspace(source: "hit one hit two", query: "hit")
        let appState = hosted.appState
        let editor = try hostedEditor(hosted)
        let session = appState.currentDocument
        appState.editorFindHost.replaceAuthority.willCheckCommitForTesting = {
            appState.workspaceMutationWriteFences.insert(ObjectIdentifier(session))
        }
        let before = EditorReplaceEffectSnapshot(appState, textView: editor)

        let result = appState.performEditorReplace(replacement: "HIT")

        appState.editorFindHost.replaceAuthority.willCheckCommitForTesting = nil
        XCTAssertEqual(result, .refused(.authoritySuperseded))
        XCTAssertEqual(
            appState.editorFindHost.replaceAuthority.lastAuthorizationRecord?.checkpoints,
            [.validation, .commit]
        )
        let after = EditorReplaceEffectSnapshot(appState, textView: editor)
        XCTAssertEqual(after.appText, before.appText)
        XCTAssertEqual(after.appVersion, before.appVersion)
        XCTAssertEqual(after.viewText, before.viewText)
        XCTAssertEqual(after.selection, before.selection)
        XCTAssertEqual(after.findSession, before.findSession)
        XCTAssertFalse(after.canUndo, "no undo group opened")
        XCTAssertEqual(after.navigation, before.navigation)

        appState.workspaceMutationWriteFences.remove(ObjectIdentifier(session))
        appState.editorFindHost.replaceAuthority.willCheckCommitForTesting = {
            appState.workspaceMutationWriteFences.insert(ObjectIdentifier(session))
            appState.workspaceMutationWriteFences.remove(ObjectIdentifier(session))
        }
        XCTAssertEqual(
            appState.performEditorReplace(replacement: "HIT"),
            .refused(.authoritySuperseded),
            "a fence set and cleared before commit still supersedes the validated command"
        )
        appState.editorFindHost.replaceAuthority.willCheckCommitForTesting = nil
        XCTAssertEqual(appState.currentDocument.text, "hit one hit two")
    }

    /// R7 bullet 6: a plan made before a fence appears is dropped before any undo group, even
    /// though the fence is gone again and every observable value has returned.
    func testHostedFenceAppearingAfterPlanningDropsThePlanBeforeAnyUndoGroup() async throws {
        let hosted = try await makeHostedReplaceWorkspace(source: "hit one hit two", query: "hit")
        let appState = hosted.appState
        let editor = try hostedEditor(hosted)
        let session = appState.currentDocument
        let plan = try appState.makeEditorReplacePlan(replacement: "HIT").get()
        let generation = appState.editorReplaceAuthorityGeneration

        try appState.beginWorkspaceNamespaceMutation([session])
        appState.endWorkspaceNamespaceMutation([session])
        XCTAssertGreaterThan(appState.editorReplaceAuthorityGeneration, generation)
        XCTAssertEqual(appState.editorReplaceAuthorizationDecision(for: session), .allowed)
        let before = EditorReplaceEffectSnapshot(appState, textView: editor)

        XCTAssertEqual(appState.deliverEditorReplacePlan(plan), .refused(.authoritySuperseded))
        XCTAssertEqual(EditorReplaceEffectSnapshot(appState, textView: editor), before)
        XCTAssertFalse(editor.undoManager?.canUndo == true)

        guard case .delivered(.replaced) = appState.performEditorReplace(replacement: "HIT") else {
            return XCTFail("A fresh explicit Replace must succeed")
        }
        XCTAssertEqual(session.text, "HIT one hit two")
    }

    /// Focus in the owned query field: the key window's responder chain has no editor, so
    /// App uses Find's own fallback eligibility and still reaches only that key window's
    /// installed editor. Without the fallback's eligibility nothing is delivered.
    func testHostedReplaceFromTheQueryFieldUsesTheFindFallback() async throws {
        let hosted = try await makeHostedReplaceWorkspace(source: "hit one hit two", query: "hit")
        let appState = hosted.appState
        let editor = try hostedEditor(hosted)
        try clickIntoFindField(in: hosted.window)
        XCTAssertTrue(isFindFieldFirstResponder(in: hosted.window))

        appState.editorFindHost.commandContextOverride = false
        let before = EditorReplaceEffectSnapshot(appState, textView: editor)
        XCTAssertEqual(
            appState.performEditorReplace(replacement: "HIT"),
            .notDelivered(.noEditorOnResponderChain)
        )
        XCTAssertEqual(EditorReplaceEffectSnapshot(appState, textView: editor), before)

        appState.editorFindHost.commandContextOverride = true
        guard case .delivered(.replaced) = appState.performEditorReplace(replacement: "HIT") else {
            return XCTFail("The find-field fallback must reach the key window's editor")
        }
        XCTAssertEqual(appState.currentDocument.text, "HIT one hit two")
        XCTAssertTrue(isFindFieldFirstResponder(in: hosted.window), "Replace does not steal focus")
    }

    /// Two windows share one `AppState`. Only the key window's installation is reached; with no
    /// key window nothing is; and a key-window change supersedes an outstanding plan.
    func testHostedReplaceReachesOnlyTheKeyWindowsInstallation() async throws {
        let hosted = try await makeHostedReplaceWorkspace(source: "hit one hit two", query: "hit")
        let appState = hosted.appState
        let session = appState.currentDocument
        let other = mountDesignatedKeyWorkspace(in: hosted.group, appState: appState, originX: 40)
        try await waitUntil("the second window installs the same document") {
            self.editorTextView(in: other) != nil
                && appState.liveEditorDocumentBindingInstallations(for: session).count == 2
        }
        let keyEditor = try hostedEditor(hosted)
        let otherEditor = try XCTUnwrap(editorTextView(in: other))
        let keyInstallation = try XCTUnwrap(
            (keyEditor.textDelegate as? MarkdownTextViewCoordinator)?.currentDocumentBindingInstallation
        )

        let plan = try appState.makeEditorReplacePlan(replacement: "HIT").get()
        designateKeyWindow(other, in: hosted.group)
        XCTAssertEqual(appState.deliverEditorReplacePlan(plan), .refused(.authoritySuperseded))
        XCTAssertEqual(session.text, "hit one hit two")

        designateKeyWindow(nil, in: hosted.group)
        XCTAssertEqual(appState.performEditorReplace(replacement: "HIT"), .notDelivered(.noKeyWindow))
        XCTAssertEqual(session.text, "hit one hit two")

        designateKeyWindow(hosted.window, in: hosted.group)
        XCTAssertTrue(hosted.window.makeFirstResponder(keyEditor))
        XCTAssertTrue(other.makeFirstResponder(otherEditor))
        guard case .delivered(.replaced) = appState.performEditorReplace(replacement: "HIT") else {
            return XCTFail("The key window's installed editor must replace")
        }
        XCTAssertEqual(session.text, "HIT one hit two")
        XCTAssertEqual(
            appState.editorWriterInstallations[ObjectIdentifier(session)],
            keyInstallation,
            "the key window's installation, not the background one, held the writer"
        )
        XCTAssertTrue(keyEditor.undoManager?.canUndo == true)
        XCTAssertFalse(otherEditor.undoManager?.canUndo == true)
    }

    /// R7 bullet 4, writer half: App authorization passes, but the installed view is stale
    /// against App's source. Writer preflight converges the view to the authoritative source
    /// and refuses; no replacement applies, no replacement undo group opens, nothing is
    /// queued, and Find recomputes counter-only before a fresh explicit Replace.
    func testHostedWriterRefusalAfterAuthorizationOnlyConverges() async throws {
        let hosted = try await makeHostedReplaceWorkspace(source: "hit one hit two", query: "hit")
        let appState = hosted.appState
        let editor = try hostedEditor(hosted)
        let session = appState.currentDocument
        let controller = appState.editorFindHost.controller
        // An App-side source change neither the installed view nor Find has observed yet.
        session.replaceText("hit zero hit one hit two", refreshStatistics: false)
        XCTAssertEqual(controller.documentBinding.revision, 0)

        let result = appState.performEditorReplace(replacement: "HIT")

        XCTAssertEqual(result, .delivered(.refused(.writerPreflightFailed)))
        XCTAssertEqual(
            appState.editorFindHost.replaceAuthority.lastAuthorizationRecord?.checkpoints,
            [.validation, .commit]
        )
        XCTAssertEqual(session.text, "hit zero hit one hit two")
        XCTAssertEqual(MarkdownTextView.textStorage(of: editor)?.string, "hit zero hit one hit two")
        XCTAssertFalse(editor.undoManager?.canUndo == true, "no replacement undo group")
        XCTAssertEqual(controller.documentBinding.revision, UInt64(session.version))
        XCTAssertEqual(controller.lastScheduleReason, .edit, "Find recomputes counter-only")
        XCTAssertEqual(controller.replacementScheduleCount, 0)

        try await focusEditorOnCurrentMatch(hosted, window: hosted.window)
        let fresh = appState.performEditorReplace(replacement: "HIT")
        guard case .delivered(.replaced) = fresh else {
            return XCTFail("A fresh explicit Replace must succeed after convergence, got \(fresh)")
        }
        XCTAssertEqual(session.text.components(separatedBy: "HIT").count, 2)
    }
}
