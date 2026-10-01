import AppKit
@testable import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import SwiftUI
import WorkspaceKit
import XCTest

/// R7: App's plain replacement authorization decision, its monotonic authority generation,
/// and untitled authority. Integration through the production `WorkspaceWindow` lives in
/// the `EditorReplaceHosted*GateTests` extensions of `EditorFindHostedGateTests`.
@MainActor
final class EditorReplaceAuthorizationAppTests: XCTestCase {
    var windows: [NSWindow] = []

    override func tearDown() {
        EditorSelectionProbe.keyWindowOverrideForTesting = nil
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
        super.tearDown()
    }

    /// Each §5.6 state refuses with its own reason; setting **and** clearing it advances the
    /// generation, and only the cleared state allows again.
    func testEverySection56StateRefusesWithItsReasonAndAdvancesTheGeneration() throws {
        let fixture = try makeAnchoredFixture()
        let appState = fixture.appState
        let session = appState.currentDocument
        XCTAssertEqual(appState.editorReplaceAuthorizationDecision(for: session), .allowed)

        for fence in try section56Fences(fixture) {
            let beforeSet = appState.editorReplaceAuthorityGeneration
            fence.set()
            XCTAssertEqual(appState.editorReplaceAuthorizationDecision(for: session), .refused(fence.reason))
            XCTAssertGreaterThan(appState.editorReplaceAuthorityGeneration, beforeSet, "\(fence.reason) set")
            let beforeClear = appState.editorReplaceAuthorityGeneration
            fence.clear()
            XCTAssertEqual(appState.editorReplaceAuthorizationDecision(for: session), .allowed, "\(fence.reason)")
            XCTAssertGreaterThan(appState.editorReplaceAuthorityGeneration, beforeClear, "\(fence.reason) clear")
        }
    }

    /// The decision is over the exact focused session, and it is not `canSave`: save-only
    /// conditions leave Replace allowed, and an untitled session is not refused for its URL.
    func testDecisionIsBoundToTheExactSessionAndIsNotCanSave() throws {
        let fixture = try makeAnchoredFixture()
        let appState = fixture.appState
        let session = appState.currentDocument
        XCTAssertEqual(
            appState.editorReplaceAuthorizationDecision(for: DocumentSession(text: "other")),
            .refused(.notCurrentSession)
        )
        appState.isSaving = true
        XCTAssertFalse(appState.canSave)
        XCTAssertEqual(appState.editorReplaceAuthorizationDecision(for: session), .allowed)
        appState.isSaving = false
        appState.workspaceMutationOperationRecoveryLoadFailed = true
        XCTAssertFalse(appState.canSave)
        XCTAssertEqual(appState.editorReplaceAuthorizationDecision(for: session), .allowed)

        let untitled = AppState(shouldRestoreLastOpenedFile: false)
        XCTAssertNil(untitled.currentDocument.fileURL)
        XCTAssertFalse(untitled.canSave)
        XCTAssertEqual(untitled.editorReplaceAuthorizationDecision(for: untitled.currentDocument), .allowed)
    }

    /// A text-recovery session restored at launch is formerly-backed authority behind a
    /// recovery fence, even though it is App's current, editable document.
    func testRestoredTextRecoverySessionIsRecoveryFenced() {
        let originalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorReplaceRecovery-\(UUID().uuidString).md")
        let store = TransientMutationTextStore()
        store.upsert(WorkspaceMutationTextRecoveryRecord(
            originalURL: originalURL,
            fileKind: .markdown,
            source: "Recovered hit",
            revision: 1,
            reason: .indeterminateMutation
        ))
        let appState = AppState(
            workspaceMutationOperationRecoveryStore: TransientMutationOperationStore(),
            workspaceMutationTextRecoveryStore: store,
            shouldRestoreLastOpenedFile: false
        )
        appState.restoreLastOpenedFileIfNeeded()

        XCTAssertEqual(appState.currentDocument.text, "Recovered hit")
        XCTAssertEqual(
            appState.editorReplaceAuthorizationDecision(for: appState.currentDocument),
            .refused(.detachedRecoveryAuthority)
        )
    }

    /// §5.7 rule 7 / R7 bullet 6: rebind, reload, rekey, focus, key-window, installation,
    /// and bar transitions advance the generation; counter and query updates do not.
    func testAuthorityGenerationAdvancesOnLifecycleFocusAndBarTransitions() throws {
        let fixture = try makeAnchoredFixture()
        let appState = fixture.appState
        appState.editorFindHost.replaceAuthority.observeKeyWindowChangesIfNeeded()
        appState.editorFindHost.commandContextOverride = true
        for (name, event) in authorityTransitions(appState) {
            let before = appState.editorReplaceAuthorityGeneration
            event()
            XCTAssertGreaterThan(appState.editorReplaceAuthorityGeneration, before, name)
        }

        let before = appState.editorReplaceAuthorityGeneration
        var ui = appState.editorFindHost.ui
        ui.matchCounterText = "1 / 9"
        ui.queryText = "changed"
        appState.setEditorFindUI(ui)
        XCTAssertEqual(
            appState.editorReplaceAuthorityGeneration,
            before,
            "counter and query changes are fenced by the query generation, not this one"
        )
    }

    /// An edit supersedes a stamp through the session's monotonic revision; the keystroke
    /// path itself adds no authorization work and does not touch the generation.
    func testTypingSupersedesAStampWithoutTouchingTheGeneration() async throws {
        let untitled = try await makeInstalledUntitled(source: "a a")
        let appState = untitled.appState
        let stamp = appState.currentEditorReplaceAuthorityStamp(for: appState.currentDocument)
        let generation = appState.editorReplaceAuthorityGeneration

        untitled.textView.insertText("x", replacementRange: NSRange(location: 3, length: 0))

        XCTAssertEqual(appState.currentDocument.text, "a ax")
        XCTAssertEqual(appState.editorReplaceAuthorityGeneration, generation)
        XCTAssertEqual(
            appState.editorReplaceAuthorizationDecision(for: stamp, session: appState.currentDocument),
            .refused(.authoritySuperseded)
        )
    }

    /// The commit closure answers from live App state: a fence present when the plan was
    /// stamped refuses with its own reason, and a later change supersedes the stamp.
    func testCommitAuthorizationReEvaluatesLiveStateAndRecordsItsReason() throws {
        let fixture = try makeAnchoredFixture()
        let appState = fixture.appState
        let session = appState.currentDocument
        appState.workspaceMutationWriteFences.insert(ObjectIdentifier(session))
        let record = EditorReplaceAuthorizationRecord()
        let authorization = appState.makeEditorReplaceCommitAuthorization(
            stamp: appState.currentEditorReplaceAuthorityStamp(for: session),
            session: session,
            record: record
        )

        XCTAssertFalse(authorization.allowsCommit())
        XCTAssertEqual(record.refusal, .workspaceMutationWriteFence)
        appState.workspaceMutationWriteFences.remove(ObjectIdentifier(session))
        XCTAssertFalse(authorization.allowsCommit())
        XCTAssertEqual(record.refusal, .authoritySuperseded)
        XCTAssertEqual(record.checkpoints, [.commit, .commit])
    }

    /// R7 bullet 5: a valid, installed untitled document has no URL and is still allowed.
    /// Replace goes through the production App → EditorKit path; only an explicit fence
    /// refuses it.
    func testInstalledUntitledDocumentIsAllowedThroughTheProductionPath() async throws {
        let untitled = try await makeInstalledUntitled(source: "a a")
        let appState = untitled.appState
        let session = appState.currentDocument
        XCTAssertNil(session.fileURL)
        XCTAssertNil(appState.activeEditorDocumentIdentity)
        XCTAssertFalse(appState.canSave)
        XCTAssertEqual(appState.editorReplaceAuthorizationDecision(for: session), .allowed)

        let result = appState.performEditorReplace(replacement: "aa")

        guard case .delivered(.replaced) = result else {
            return XCTFail("An installed untitled document must replace, got \(result)")
        }
        XCTAssertEqual(session.text, "aa a")
        XCTAssertEqual(session.version, 1)
        XCTAssertTrue(untitled.textView.undoManager?.canUndo == true)
        XCTAssertEqual(
            appState.editorFindHost.replaceAuthority.lastAuthorizationRecord?.checkpoints,
            [.validation, .commit]
        )

        try await waitUntil { appState.editorFindHost.controller.session != nil }
        try appState.beginWorkspaceNamespaceMutation([session])
        XCTAssertEqual(
            appState.performEditorReplace(replacement: "b"),
            .refused(.workspaceMutationWriteFence)
        )
        appState.endWorkspaceNamespaceMutation([session])
        XCTAssertEqual(session.text, "aa a")
        XCTAssertEqual(appState.editorReplaceAuthorizationDecision(for: session), .allowed)
    }
}
