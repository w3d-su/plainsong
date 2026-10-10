import AppKit
@testable import EditorKit
import Foundation
@testable import Plainsong
@testable import WorkspaceKit
import XCTest

@MainActor
extension EditorFindHostedGateTests {
    func testHostedFindNavigationSurvivesWorkspaceRefreshBeforeEditorAppliesIt() async throws {
        let source = "prefix hit one hit two"
        let fixture = try makeWorkspaceFixture(files: ["post.md": source])
        let appState = fixture.appState
        appState.setLayoutMode(.sourceOnly)
        appState.openExternalFile(fixture.root)
        try await waitUntil("workspace document opens") {
            appState.currentDocument.fileURL?.lastPathComponent == "post.md"
                && appState.isWorkspaceSearchReady
        }
        appState.workspaceWatcher?.stop()
        let group = makeHostedWorkspaceGroup(fixture: fixture)
        // No editor is mounted yet: publication cannot accidentally apply before refresh.
        openFindBar(appState, query: "hit")
        try await waitUntil("Find publishes its navigation before mounting") {
            if case .navigate = appState.editorNavigationCommand { return true }
            return false
        }
        let command = try XCTUnwrap(appState.editorNavigationCommand)
        let generation = appState.editorFindHost.controller.queryGeneration
        let match = try XCTUnwrap(appState.editorFindHost.controller.session?.currentMatch?.range)

        // The same entry point the filesystem watcher uses; source and document stay intact.
        appState.refreshWorkspaceAfterFileSystemChange()
        XCTAssertEqual(appState.editorNavigationCommand, command, hostedFindTimeoutState(appState))
        let window = mountDesignatedKeyWorkspace(in: group, appState: appState)
        designateKeyWindow(window, in: group)
        try await waitUntil("the original Find match applies without another Find action") {
            self.appliedRange(in: window) == match
                && appState.workspaceInstalledCaptureGeneration == appState.workspaceGeneration
        }
        let editor = try XCTUnwrap(editorTextView(in: window))
        XCTAssertEqual(appState.currentDocument.text, source)
        XCTAssertEqual(appState.currentDocument.version, 0)
        XCTAssertEqual(appState.editorFindHost.controller.queryGeneration, generation)
        XCTAssertEqual(appState.editorNavigationCommand, command)
        XCTAssertFalse(editor.undoManager?.canUndo == true)
    }

    /// Holds the main actor synchronously for `seconds`, so a watcher debounce that fires
    /// meanwhile can only queue — not run — its `Task { @MainActor }` hop behind this turn.
    /// (`Thread.sleep` must live in a synchronous function to be callable here.)
    private func holdMainActorForQueuedHop(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    /// Handoff 27c M2: the watcher's `stop()` is a hard boundary for handlers that begin
    /// after it, but a handler that began before `stop()` still queues its
    /// `Task { @MainActor }` hop behind it — the hop the CI flake took. Only the App guard
    /// (`watcher === workspaceWatcher && !watcher.isStopped`) drops it. Blocking the main
    /// actor past the 300 ms debounce queues such a hop deterministically.
    func testHostedWatcherHopQueuedBehindStopIsDropped() async throws {
        let hosted = try await makeHostedEditorWorkspace(source: "hit one hit two")
        let appState = hosted.appState
        let watcher = try XCTUnwrap(appState.workspaceWatcher)
        try await waitForHostedReplaceObservationQuiescence(hosted)
        let session = appState.currentDocument
        let identity = ObjectIdentifier(session)
        let authorityGeneration = appState.editorReplaceAuthorityGeneration
        let diskGeneration = appState.currentExternalDiskEventGeneration(for: session)

        watcher.simulateDeliveredEventForTesting()
        // The debounce fires and queues its main-actor hop while this turn blocks; the hop
        // then lands behind stop(), the interleaving the workspaceWatcher guard covers.
        holdMainActorForQueuedHop(0.9)
        appState.workspaceWatcher?.stop()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertNil(appState.externalDiskInspectionTasks[identity], "no disk inspection")
        XCTAssertEqual(
            appState.currentExternalDiskEventGeneration(for: session),
            diskGeneration,
            "handleExternalChange never ran"
        )
        XCTAssertEqual(
            appState.editorReplaceAuthorityGeneration,
            authorityGeneration,
            "no authority-generation advance"
        )
        XCTAssertEqual(
            appState.editorReplaceAuthorizationDecision(for: session),
            .allowed,
            "no externalObservationPending"
        )
        #if DEBUG
            XCTAssertTrue(
                appState.editorFindHost.replaceBarTrace.contains {
                    $0.contains("watcherHop dropped reason=stopped")
                },
                "the queued hop ran and the guard dropped it"
            )
        #endif
    }

    /// The same hop from a watcher the workspace has since replaced: the identity clause
    /// drops it even though the old watcher was never stopped.
    func testHostedWatcherHopFromAReplacedWatcherIsDropped() async throws {
        let hosted = try await makeHostedEditorWorkspace(source: "hit one hit two")
        let appState = hosted.appState
        let watcher = try XCTUnwrap(appState.workspaceWatcher)
        // The original watcher stays live through the swap below; stop it at test end so a
        // late real FSEvent cannot deliver into a later test's workspace state.
        defer { watcher.stop() }
        try await waitForHostedReplaceObservationQuiescence(hosted)
        let session = appState.currentDocument
        let identity = ObjectIdentifier(session)
        let authorityGeneration = appState.editorReplaceAuthorityGeneration
        let diskGeneration = appState.currentExternalDiskEventGeneration(for: session)

        watcher.simulateDeliveredEventForTesting()
        holdMainActorForQueuedHop(0.9)
        // Replace the live watcher without stopping it: the queued hop's watcher is no
        // longer workspaceWatcher, so only the identity clause can drop it.
        appState.workspaceWatcher = WorkspaceEventWatcher(rootURL: hosted.fixture.root) {}
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertNil(appState.externalDiskInspectionTasks[identity], "no disk inspection")
        XCTAssertEqual(
            appState.currentExternalDiskEventGeneration(for: session),
            diskGeneration,
            "handleExternalChange never ran"
        )
        XCTAssertEqual(
            appState.editorReplaceAuthorityGeneration,
            authorityGeneration,
            "no authority-generation advance"
        )
        XCTAssertEqual(
            appState.editorReplaceAuthorizationDecision(for: session),
            .allowed,
            "no externalObservationPending"
        )
        #if DEBUG
            XCTAssertTrue(
                appState.editorFindHost.replaceBarTrace.contains {
                    $0.contains("watcherHop dropped reason=replaced")
                },
                "the queued hop ran and the guard dropped it"
            )
        #endif
    }

    #if DEBUG
        /// Handoff 27c M3: an accepted hop attributes the resulting `handleExternalChange`
        /// to the hop's own `refreshWorkspaceAfterFileSystemChange()` site in
        /// `App/AppState+Workspace.swift`. Passing row-test runs show the only
        /// `advancing=true` producers near the press are test-injected refreshes and this
        /// watcher hop: a real FSEvent for fixture-setup activity under the root (e.g. the
        /// fixture's own `post.md` write delivered across the `sinceNow` boundary)
        /// debounces ~300 ms and hops onto the main actor while the watcher is still live
        /// — proven by matching `ObjectIdentifier`s and `isStopped=false` ~40 ms before
        /// `fixtureStopped` — so the hop legitimately runs before
        /// `makeHostedBatchWorkspace`'s `stop()`. The readiness wait in
        /// `startHeldBarReplaceAll` absorbs any still-pending observation before the
        /// press, and hops arriving after `stop()` are dropped by the guard.
        func testHostedWatcherHopAcceptedAttributesExternalChangeToTheHop() async throws {
            let hosted = try await makeHostedEditorWorkspace(source: "hit one hit two")
            let appState = hosted.appState
            let watcher = try XCTUnwrap(appState.workspaceWatcher)
            try await waitForHostedReplaceObservationQuiescence(hosted)

            watcher.simulateDeliveredEventForTesting()
            try await waitUntil("the queued watcher hop is accepted and attributed") {
                let trace = appState.editorFindHost.replaceBarTrace
                return trace.contains { $0.contains("watcherHop accepted") }
                    && trace.contains { $0.contains("handleExternalChange file=post.md advancing=true") }
            }
            let trace = appState.editorFindHost.replaceBarTrace
            let hopIndex = try XCTUnwrap(
                trace.lastIndex { $0.contains("watcherHop accepted") },
                "the hop was accepted"
            )
            let entry = try XCTUnwrap(
                trace.last { $0.contains("handleExternalChange file=post.md advancing=true") }
            )
            XCTAssertTrue(
                entry.contains("(Plainsong/AppState+Workspace.swift:"),
                "the producer is the openWorkspace watcher hop; got: \(entry)"
            )
            XCTAssertGreaterThan(
                try XCTUnwrap(trace.lastIndex { $0 == entry }),
                hopIndex,
                "the external change is recorded after the accepted hop: \(trace.joined(separator: "\n"))"
            )
        }
    #endif
}
