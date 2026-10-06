import AppKit
@testable import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import XCTest

/// A window whose key status a Replace test designates when it mounts an editor by hand
/// (the untitled fixture). Hosted `WorkspaceWindow`s use `DesignatedKeyWindow` instead;
/// both exist because a test process cannot rely on `makeKeyAndOrderFront`.
final class EditorReplaceKeyWindow: NSWindow {
    var isDesignatedKey = false

    override var isKeyWindow: Bool {
        isDesignatedKey
    }
}

/// App recovery and reconciliation authority an App refusal must leave untouched.
struct EditorReplaceRecoveryAuthority: Equatable {
    let pendingExternalTexts: [URL: String]
    let pendingExternalVersionURLs: Set<URL>
    let externalChangePromptURL: URL?
    let missingFilePromptURL: URL?
    let checkAgainPrompt: IndeterminateFileWriteReconciliationPrompt?
    let detachedSessionURLs: Set<URL>
    let indeterminateWriteSessions: Set<ObjectIdentifier>
    let deferredResolutions: [URL: DeferredExternalChangeResolution]
    let reloadTaskSessions: Set<ObjectIdentifier>
    let pendingApplicationSessions: Set<ObjectIdentifier>
    let writeFences: Set<ObjectIdentifier>
    let indeterminateMutationSessions: Set<ObjectIdentifier>
    let pendingSourceInstallations: Set<EditorDocumentBindingInstallation>
    let mutationRecoveryIDs: Set<UUID>

    @MainActor
    init(_ appState: AppState) {
        pendingExternalTexts = appState.pendingExternalTexts
        pendingExternalVersionURLs = Set(appState.pendingExternalFileVersions.keys)
        externalChangePromptURL = appState.externalChangePrompt?.fileURL
        missingFilePromptURL = appState.missingFilePrompt?.fileURL
        checkAgainPrompt = appState.indeterminateFileWriteReconciliationPrompt
        detachedSessionURLs = appState.detachedSessionURLs
        indeterminateWriteSessions = Set(appState.indeterminateSessionWrites.keys)
        deferredResolutions = appState.deferredExternalChangeResolutions
        reloadTaskSessions = Set(appState.externalReloadTasks.keys)
        pendingApplicationSessions = Set(appState.pendingExternalReloadApplications.keys)
        writeFences = appState.workspaceMutationWriteFences
        indeterminateMutationSessions = appState.indeterminateWorkspaceMutationSessions
        pendingSourceInstallations = Set(appState.pendingEditorSourceInstallations.keys)
        mutationRecoveryIDs = Set(appState.workspaceMutationRecoveries.keys)
    }
}

/// R7 bullet 4: everything an App refusal must leave unchanged — source, selection,
/// ordinal, fields, undo, progress (the chrome state), navigation, and recovery authority.
struct EditorReplaceEffectSnapshot: Equatable {
    let appText: String
    let appVersion: Int
    let isDirty: Bool
    let viewText: String?
    let selection: NSRange?
    let findSession: EditorFindSession?
    let queryGeneration: UInt64
    let findUI: EditorFindUIState
    let canUndo: Bool
    let canRedo: Bool
    let navigation: EditorNavigationCommand?
    let pendingNavigation: EditorNavigationRequest?
    let recovery: EditorReplaceRecoveryAuthority

    @MainActor
    init(_ appState: AppState, textView: MarkdownSTTextView?) {
        appText = appState.currentDocument.text
        appVersion = appState.currentDocument.version
        isDirty = appState.currentDocument.isDirty
        viewText = textView.map { MarkdownTextView.textStorage(of: $0)?.string ?? $0.text ?? "" }
        selection = textView?.selectedRange()
        findSession = appState.editorFindHost.controller.session
        queryGeneration = appState.editorFindHost.controller.queryGeneration
        findUI = appState.editorFindHost.ui
        canUndo = textView?.undoManager?.canUndo == true
        canRedo = textView?.undoManager?.canRedo == true
        navigation = appState.editorNavigationCommand
        pendingNavigation = (textView?.textDelegate as? MarkdownTextViewCoordinator)?
            .navigationState.pendingRequest
        recovery = EditorReplaceRecoveryAuthority(appState)
    }
}

/// One production `WorkspaceWindow` on a workspace document, key, with the find bar open.
@MainActor
struct HostedReplaceWorkspace {
    let fixture: WorkspaceFixture
    let group: HostedWorkspaceGroup
    let window: DesignatedKeyWindow

    var appState: AppState {
        fixture.appState
    }

    var postURL: URL {
        fixture.root.appendingPathComponent("post.md")
    }
}

@MainActor
extension EditorFindHostedGateTests {
    /// Setup must finish self-triggered fixture inspections before a test injects its own
    /// refusal state. This waits on external observation only, leaving every product fence intact.
    func waitForHostedReplaceObservationQuiescence(_ hosted: HostedReplaceWorkspace) async throws {
        let appState = hosted.appState
        let session = appState.currentDocument
        let identity = ObjectIdentifier(session)
        try await waitUntil("hosted Replace setup has no pending external observation") {
            guard appState.externalDiskInspectionTasks[identity] == nil,
                  appState.externalReloadTasks[identity] == nil,
                  appState.pendingExternalReloadApplications[identity] == nil,
                  let url = appState.sessionStateURL(for: session)
            else { return false }
            return appState.pendingExternalTexts[url] == nil
                && appState.pendingExternalFileVersions[url] == nil
                && appState.deferredExternalChangeResolutions[url] == nil
                && appState.externalChangePrompt?.fileURL != url
        }
    }

    /// EditorKit reads the key window through the shared probe seam; point it at whichever
    /// window of `group` is designated key, and reset it after the test.
    func designateReplaceKeyWindow(in group: HostedWorkspaceGroup) {
        EditorSelectionProbe.keyWindowOverrideForTesting = { [weak group] in
            group?.windows.first(where: \.isKeyWindow)
        }
        addTeardownBlock { @MainActor in
            EditorSelectionProbe.keyWindowOverrideForTesting = nil
        }
    }

    /// Waits for the current match to be applied in `window`'s editor, moves focus to that
    /// editor (after the query field consumed its focus request), and clears undo history.
    func focusEditorOnCurrentMatch(
        _ hosted: HostedReplaceWorkspace,
        window: NSWindow
    ) async throws {
        let appState = hosted.appState
        try await waitUntil("Find applies the current match in the hosted editor") {
            guard let match = appState.editorFindHost.controller.session?.currentMatch else {
                return false
            }
            return self.appliedRange(in: window) == match.range
                && appState.editorFindHost.ui.focusAppliedID == appState.editorFindHost.ui.focusRequestID
        }
        let editor = try XCTUnwrap(editorTextView(in: window))
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.undoManager?.removeAllActions()
    }

    func hostedEditor(_ hosted: HostedReplaceWorkspace) throws -> MarkdownSTTextView {
        try XCTUnwrap(editorTextView(in: hosted.window))
    }

    /// Makes the local edit conflict with a disk change and waits for the Reload / Keep Mine
    /// prompt, driving the watcher refresh the way the F4b hosted gates do.
    func recordExternalConflict(_ hosted: HostedReplaceWorkspace, disk: String) async throws {
        let appState = hosted.appState
        appState.workspaceWatcher?.stop()
        try disk.write(to: hosted.postURL, atomically: true, encoding: .utf8)
        appState.refreshWorkspaceAfterFileSystemChange()
        try await waitUntil("the Reload / Keep Mine prompt appears") {
            appState.externalChangePrompt?.fileURL.lastPathComponent == "post.md"
                && appState.externalDiskInspectionTasks.isEmpty
        }
    }

    /// Asserts an App refusal with its reason and zero effect (R7 bullet 4).
    func assertAppRefusal(
        _ hosted: HostedReplaceWorkspace,
        _ expected: EditorReplaceAuthorizationRefusal,
        replacement: String = "HIT",
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let appState = hosted.appState
        let editor = try hostedEditor(hosted)
        let before = EditorReplaceEffectSnapshot(appState, textView: editor)
        let generationBefore = appState.editorReplaceAuthorityGeneration

        let result = appState.performEditorReplace(replacement: replacement)

        XCTAssertEqual(result, .refused(expected), file: file, line: line)
        XCTAssertEqual(
            appState.editorFindHost.replaceAuthority.lastAuthorizationRecord?.checkpoints,
            [.validation],
            "an App refusal is decided before the command reaches any editor",
            file: file,
            line: line
        )
        XCTAssertEqual(EditorReplaceEffectSnapshot(appState, textView: editor), before, file: file, line: line)
        XCTAssertEqual(
            appState.editorReplaceAuthorityGeneration,
            generationBefore,
            "a refusal changes no authority input",
            file: file,
            line: line
        )
    }
}
