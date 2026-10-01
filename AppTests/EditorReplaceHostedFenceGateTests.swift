import AppKit
@testable import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import WorkspaceKit
import XCTest

/// R7 integration matrix on the production `WorkspaceWindow`: every §5.6 fence is reached
/// through its real App entry point, and Replace driven through the production App →
/// EditorKit delivery path is refused with zero effect. Each case then proves the refusal
/// was the fence's by clearing it, where the fixture allows, and replacing for real.
@MainActor
extension EditorFindHostedGateTests {
    func testHostedReplaceRefusesWhileAnExternalChangeAwaitsAChoice() async throws {
        let hosted = try await makeHostedReplaceWorkspace(
            source: "hit one",
            query: "hit",
            localEdit: "hit local hit local"
        )
        try await recordExternalConflict(hosted, disk: "hit disk")

        try assertAppRefusal(hosted, .externalChangeAwaitingChoice)
    }

    func testHostedReplaceRefusesWhileReloadIsSuspendedBehindPendingEditorSource() async throws {
        let hosted = try await makeHostedReplaceWorkspace(
            source: "hit one",
            query: "hit",
            localEdit: "hit local hit local"
        )
        let appState = hosted.appState
        try await recordExternalConflict(hosted, disk: "hit disk")
        let editor = try hostedEditor(hosted)
        editor.setMarkedText(
            "ㄅ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: .notFound
        )
        XCTAssertTrue(appState.hasPendingEditorSource(for: appState.currentDocument))
        try assertAppRefusal(hosted, .pendingEditorSource)

        appState.reloadExternallyChangedFile()
        let stateURL = try XCTUnwrap(appState.sessionStateURL(for: appState.currentDocument))
        XCTAssertEqual(appState.deferredExternalChangeResolutions[stateURL], .reload)
        XCTAssertTrue(appState.externalReloadTasks.isEmpty, "the Reload read is suspended")

        try assertAppRefusal(hosted, .externalResolutionSuspended)
        editor.unmarkText()
    }

    func testHostedReplaceRefusesAReadableIndeterminateWriteQuarantine() async throws {
        let hosted = try await makeHostedReplaceWorkspace(
            source: "hit one",
            query: "hit",
            localEdit: "hit local hit local"
        )
        let appState = hosted.appState
        appState.anchoredFileSaveOverride = { _, _, _ in
            .committedButIndeterminate(WorkspaceIndeterminateFileWrite(
                reason: .durabilityFailed,
                preparedMetadata: nil,
                recoveryArtifact: .none
            ))
        }
        XCTAssertThrowsError(try appState.saveCurrentDocument())
        appState.anchoredFileSaveOverride = nil
        XCTAssertNotNil(appState.indeterminateSessionWrites[ObjectIdentifier(appState.currentDocument)])
        XCTAssertEqual(
            appState.externalChangePrompt?.fileURL.lastPathComponent,
            "post.md",
            "a readable quarantine is presented through Reload / Keep Mine"
        )

        try assertAppRefusal(hosted, .indeterminateWriteQuarantine)
    }

    func testHostedReplaceRefusesAnUnavailableCheckAgainQuarantine() async throws {
        let hosted = try await makeHostedReplaceWorkspace(
            source: "hit one",
            query: "hit",
            localEdit: "hit local hit local"
        )
        let appState = hosted.appState
        let post = hosted.postURL
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: post.path)
        }
        appState.anchoredFileSaveOverride = { _, _, _ in
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: post.path)
            return .committedButIndeterminate(WorkspaceIndeterminateFileWrite(
                reason: .durabilityFailed,
                preparedMetadata: nil,
                recoveryArtifact: .none
            ))
        }
        XCTAssertThrowsError(try appState.saveCurrentDocument())
        appState.anchoredFileSaveOverride = nil
        XCTAssertEqual(appState.indeterminateFileWriteReconciliationPrompt?.state, .unreadable)
        XCTAssertNil(appState.externalChangePrompt)

        try assertAppRefusal(hosted, .indeterminateWriteQuarantine)
        appState.refreshIndeterminateFileWriteReconciliation()
        try assertAppRefusal(hosted, .indeterminateWriteQuarantine)
    }

    func testHostedReplaceRefusesDuringAWorkspaceMutationWriteFence() async throws {
        let hosted = try await makeHostedReplaceWorkspace(source: "hit one hit two", query: "hit")
        let appState = hosted.appState
        let session = appState.currentDocument
        try appState.beginWorkspaceNamespaceMutation([session])

        try assertAppRefusal(hosted, .workspaceMutationWriteFence)

        appState.endWorkspaceNamespaceMutation([session])
        guard case .delivered(.replaced) = appState.performEditorReplace(replacement: "HIT") else {
            return XCTFail("Replace must be allowed once the write fence clears")
        }
        XCTAssertEqual(session.text, "HIT one hit two")
    }

    func testHostedReplaceRefusesWhileEditorSourceIsPending() async throws {
        let hosted = try await makeHostedReplaceWorkspace(source: "hit one hit two", query: "hit")
        let editor = try hostedEditor(hosted)
        editor.setMarkedText(
            "ㄅ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: .notFound
        )

        try assertAppRefusal(hosted, .pendingEditorSource)
        editor.unmarkText()
    }

    func testHostedReplaceRefusesARecoveryFencedDetachedSession() async throws {
        let hosted = try await makeHostedReplaceWorkspace(
            source: "hit one",
            query: "hit",
            localEdit: "hit local hit local"
        )
        let appState = hosted.appState
        appState.workspaceWatcher?.stop()
        try FileManager.default.removeItem(at: hosted.postURL)
        appState.refreshWorkspaceAfterFileSystemChange()
        try await waitUntil("the missing-file recovery prompt appears") {
            appState.missingFilePrompt?.fileURL.lastPathComponent == "post.md"
        }
        let stateURL = try XCTUnwrap(appState.sessionStateURL(for: appState.currentDocument))
        XCTAssertTrue(appState.detachedSessionURLs.contains(stateURL))

        try assertAppRefusal(hosted, .detachedRecoveryAuthority)
    }
}
