import AppKit
@testable import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import XCTest

/// R7 resolution lifecycle on the production `WorkspaceWindow`: Replace stays refused while
/// Reload has not converged every live editor, and Reload / Keep Mine completion recomputes
/// Find counter-only and requires a fresh explicit Replace (nothing is queued).
@MainActor
extension EditorFindHostedGateTests {
    /// Two windows install the same session. Reload applies, one installation converges and
    /// the other cannot yet: Replace is refused for partial live-editor convergence. When
    /// the second converges, Reload completes, Find recounts counter-only from the accepted
    /// disk source, a plan made before the conflict is superseded, and a fresh Replace works.
    func testHostedReplaceWaitsForEveryLiveEditorToConvergeAfterReload() async throws {
        let hosted = try await makeHostedReplaceWorkspace(
            source: "hit one",
            query: "hit",
            localEdit: "hit local hit local"
        )
        let appState = hosted.appState
        let session = appState.currentDocument
        let staleEditor = mountDesignatedKeyWorkspace(in: hosted.group, appState: appState, originX: 40)
        try await waitUntil("the second window installs the same document") {
            appState.liveEditorDocumentBindingInstallations(for: session).count == 2
        }
        let staleInstallation = try XCTUnwrap(
            (editorTextView(in: staleEditor)?.textDelegate as? MarkdownTextViewCoordinator)?
                .currentDocumentBindingInstallation
        )
        let prePrompt = try appState.makeEditorReplacePlan(replacement: "HIT").get()
        try await recordExternalConflict(hosted, disk: "hit disk hit disk hit disk")
        let synchronizer = try XCTUnwrap(appState.editorDocumentSourceSynchronizers[staleInstallation])
        appState.editorDocumentSourceSynchronizers[staleInstallation] = { _ in false }

        appState.reloadExternallyChangedFile()
        try await waitUntil("Reload applies but one installation has not converged") {
            appState.pendingExternalReloadApplications[ObjectIdentifier(session)] != nil
                && appState.externalReloadTasks[ObjectIdentifier(session)] != nil
                && session.text == "hit disk hit disk hit disk"
        }
        try await focusEditorOnCurrentMatch(hosted, window: hosted.window)
        try assertAppRefusal(hosted, .liveEditorConvergencePending)

        appState.editorDocumentSourceSynchronizers[staleInstallation] = synchronizer
        let generation = appState.editorReplaceAuthorityGeneration
        appState.synchronizePendingExternalReloadIfPossible(for: session)
        XCTAssertNil(appState.pendingExternalReloadApplications[ObjectIdentifier(session)])
        XCTAssertNil(appState.externalReloadTasks[ObjectIdentifier(session)])
        XCTAssertGreaterThan(appState.editorReplaceAuthorityGeneration, generation)

        try await assertCounterOnlyRecount(appState, source: "hit disk hit disk hit disk", total: 3)
        XCTAssertEqual(appState.deliverEditorReplacePlan(prePrompt), .refused(.authoritySuperseded))
        XCTAssertEqual(session.text, "hit disk hit disk hit disk", "nothing was queued")

        try await focusEditorOnCurrentMatch(hosted, window: hosted.window)
        guard case .delivered(.replaced) = appState.performEditorReplace(replacement: "HIT") else {
            return XCTFail("A fresh explicit Replace must succeed after Reload converges")
        }
        XCTAssertEqual(session.text.components(separatedBy: "HIT").count, 2)
    }

    /// Keep Mine keeps identity, revision, and the local source, so Find's session already
    /// describes the accepted source: completion revalidates it without a second scan or any
    /// channel publication (F4b), and still supersedes every earlier plan.
    func testHostedKeepMineCompletionRevalidatesAndRequiresAFreshReplace() async throws {
        let local = "hit local hit local"
        let hosted = try await makeHostedReplaceWorkspace(
            source: "hit one",
            query: "hit",
            localEdit: local
        )
        let appState = hosted.appState
        let session = appState.currentDocument
        let controller = appState.editorFindHost.controller
        let prePrompt = try appState.makeEditorReplacePlan(replacement: "HIT").get()
        try await recordExternalConflict(hosted, disk: "hit disk")
        let findBefore = controller.session
        let completedBefore = controller.completedMatchCount
        let generation = appState.editorReplaceAuthorityGeneration

        appState.keepMineForExternallyChangedFile()
        try await waitUntil("Keep Mine converges and completes") {
            appState.externalChangePrompt == nil
                && appState.externalReloadTasks.isEmpty
                && appState.pendingExternalReloadApplications.isEmpty
        }

        XCTAssertGreaterThan(appState.editorReplaceAuthorityGeneration, generation)
        XCTAssertEqual(session.text, local)
        XCTAssertEqual(controller.documentBinding.text, local)
        XCTAssertEqual(controller.documentBinding.revision, UInt64(session.version))
        XCTAssertEqual(controller.session, findBefore, "the retained session is the recount")
        XCTAssertEqual(controller.completedMatchCount, completedBefore, "no second scan")
        XCTAssertEqual(appState.deliverEditorReplacePlan(prePrompt), .refused(.authoritySuperseded))
        XCTAssertEqual(session.text, local, "nothing was queued")

        guard case .delivered(.replaced) = appState.performEditorReplace(replacement: "HIT") else {
            return XCTFail("A fresh explicit Replace must succeed after Keep Mine")
        }
        XCTAssertEqual(session.text, "HIT local hit local")
    }

    /// Reload completion without a second window: the counter comes from the accepted disk
    /// source, no navigation is emitted, and a plan made before the conflict cannot commit.
    func testHostedReloadCompletionRecountsCounterOnlyAndRequiresAFreshReplace() async throws {
        let hosted = try await makeHostedReplaceWorkspace(
            source: "hit one",
            query: "hit",
            localEdit: "hit local hit local"
        )
        let appState = hosted.appState
        let session = appState.currentDocument
        let prePrompt = try appState.makeEditorReplacePlan(replacement: "HIT").get()
        try await recordExternalConflict(hosted, disk: "hit disk hit disk hit disk")

        appState.reloadExternallyChangedFile()
        try await waitUntil("Reload converges and completes") {
            appState.externalChangePrompt == nil
                && appState.externalReloadTasks.isEmpty
                && appState.pendingExternalReloadApplications.isEmpty
                && session.text == "hit disk hit disk hit disk"
        }

        try await assertCounterOnlyRecount(appState, source: "hit disk hit disk hit disk", total: 3)
        XCTAssertEqual(appState.deliverEditorReplacePlan(prePrompt), .refused(.authoritySuperseded))
        XCTAssertEqual(session.text, "hit disk hit disk hit disk", "nothing was queued")

        try await focusEditorOnCurrentMatch(hosted, window: hosted.window)
        guard case .delivered(.replaced) = appState.performEditorReplace(replacement: "HIT") else {
            return XCTFail("A fresh explicit Replace must succeed after Reload")
        }
        XCTAssertEqual(session.text.components(separatedBy: "HIT").count, 2)
    }

    /// Find recounts from `source` at App's revision without emitting a navigation.
    private func assertCounterOnlyRecount(
        _ appState: AppState,
        source: String,
        total: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let controller = appState.editorFindHost.controller
        try await waitUntil("Find recounts the accepted source") {
            controller.session?.total == total
        }
        XCTAssertEqual(controller.documentBinding.text, source, file: file, line: line)
        XCTAssertEqual(
            controller.documentBinding.revision,
            UInt64(appState.currentDocument.version),
            file: file,
            line: line
        )
        XCTAssertNotEqual(controller.lastScheduleReason, .query, file: file, line: line)
        XCTAssertEqual(controller.replacementScheduleCount, 0, file: file, line: line)
        if case .navigate = controller.pendingNavigationCommand {
            XCTFail("the recount must not navigate", file: file, line: line)
        }
    }
}
