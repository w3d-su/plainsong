import AppKit
@testable import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import WorkspaceKit
import XCTest

/// F4b UI-visibility half on the production `WorkspaceWindow`: each document-lifecycle
/// transition is driven through its real App entry point while the find bar is mounted.
///
/// Every invalidating transition (Reload, rename, both Save Copy variants, missing-file close)
/// also proves the shared navigation channel: a find navigation published (or still computing)
/// before it cannot land in the hosted editor afterwards. Keep Mine keeps identity and
/// revision, so it invalidates nothing: its case proves Keep Mine publishes nothing at all on
/// the channel and an earlier find navigation does not land again.
@MainActor
extension EditorFindHostedGateTests {
    func testHostedKeepMineKeepsTheFindBarOnTheLocalSourceWithoutNavigation() async throws {
        let fixture = try makeWorkspaceFixture(files: ["post.md": "hit one"])
        let appState = fixture.appState
        appState.setLayoutMode(.sourceOnly)
        // The local edit must still be dirty when the disk changes, or Reload is silent.
        appState.preferences.setAutosaveIntervalSeconds(30)
        appState.openExternalFile(fixture.root)
        try await waitUntil("workspace document opens") {
            appState.currentDocument.fileURL?.lastPathComponent == "post.md"
        }
        let host = makeWorkspaceHost(appState: appState)
        registerTeardown(host: host, fixture: fixture)
        let window = host.window

        let local = "hit local hit local"
        appState.replaceDocumentText(local)
        let ranges = matchRanges(of: "hit", in: local)
        openFindBar(appState, query: "hit")
        try await waitUntil("find selects the first local match in the hosted editor") {
            self.appliedRange(in: window) == ranges[0]
                && appState.editorFindHost.controller.session?.total == 2
        }
        let field = try XCTUnwrap(findQueryField(in: window))

        // A find navigation lands before the conflict; the user then moves the caret away.
        _ = try publishFindStep(appState, expecting: ranges[1])
        try await waitUntil("⌘G lands on the second local match") {
            self.appliedRange(in: window) == ranges[1]
        }
        let caret = NSRange(location: 0, length: 0)
        try XCTUnwrap(editorTextView(in: window)).textSelection = caret
        try await waitUntil("caret moved away from the find match") {
            self.appliedRange(in: window) == caret
        }

        // The test drives the refresh the FSEvents watcher would drive; its debounced duplicate
        // must not restart conflict resolution while the channel is being observed.
        appState.workspaceWatcher?.stop()
        let post = fixture.root.appendingPathComponent("post.md")
        try "hit disk hit disk hit disk".write(to: post, atomically: true, encoding: .utf8)
        appState.refreshWorkspaceAfterFileSystemChange()
        try await waitUntil("conflict banner appears above the still-mounted bar") {
            appState.externalChangePrompt?.fileURL.lastPathComponent == "post.md"
        }
        XCTAssertTrue(findQueryField(in: window) === field)
        let channelBeforeKeepMine = appState.editorNavigationCommand
        XCTAssertNotNil(channelBeforeKeepMine, "precondition: the channel already carries find commands")

        appState.keepMineForExternallyChangedFile()
        try await waitUntil("Keep Mine resolves through the hosted editor installation") {
            appState.externalChangePrompt == nil
                && appState.externalReloadTasks.isEmpty
                && appState.pendingExternalReloadApplications.isEmpty
        }

        // Keep Mine keeps identity and revision, so Find has nothing to invalidate: the
        // counter still describes the local source, and no navigation lands or re-lands.
        try await assertFindBarStayedMounted(
            field,
            query: "hit",
            selection: caret,
            appState: appState,
            window: window
        )
        XCTAssertEqual(appState.currentDocument.text, local)
        XCTAssertEqual(appState.editorFindHost.controller.documentBinding.text, local)
        XCTAssertEqual(appState.editorFindHost.controller.session?.total, 2)
        XCTAssertEqual(appState.editorFindHost.ui.matchCounterText, "2 / 2")
        XCTAssertEqual(
            appState.editorNavigationCommand,
            channelBeforeKeepMine,
            "Keep Mine must publish nothing on the shared channel: no navigation and no cancel"
        )
        XCTAssertNil(try XCTUnwrap(editorCoordinator(in: window)).navigationState.pendingRequest)
    }

    func testHostedRenameRekeysFindWithoutAutoJumpAndCancelsAPublishedNavigation() async throws {
        let source = "hit one hit two"
        let fixture = try makeWorkspaceFixture(files: ["post.md": source])
        let appState = fixture.appState
        appState.setLayoutMode(.sourceOnly)
        appState.openExternalFile(fixture.root)
        try await waitUntil("workspace document opens") {
            appState.currentDocument.fileURL?.lastPathComponent == "post.md"
        }
        let host = makeWorkspaceHost(appState: appState)
        registerTeardown(host: host, fixture: fixture)
        let window = host.window
        let ranges = matchRanges(of: "hit", in: source)

        openFindBar(appState, query: "hit")
        try await waitUntil("find selects the first match in the hosted editor") {
            self.appliedRange(in: window) == ranges[0]
                && appState.editorFindHost.controller.session?.total == 2
        }
        let field = try XCTUnwrap(findQueryField(in: window))
        let originalIdentity = try XCTUnwrap(appState.activeEditorDocumentIdentity)
        // `renameWorkspaceItem(id:to:)` silently no-ops until the workspace capture installed.
        try await waitUntil("workspace capture settles before the sidebar rename") {
            appState.workspaceInstalledCaptureGeneration == appState.workspaceGeneration
        }
        let nodeID = try XCTUnwrap(
            appState.workspaceTree?.root.children.first { $0.relativePath == "post.md" }?.id
        )

        // Sidebar rename commits in the same main-actor turn the ⌘G was published in.
        let stale = try publishFindStep(appState, expecting: ranges[1])
        appState.renameWorkspaceItem(id: nodeID, to: "renamed.md")
        let cancelID = try XCTUnwrap(assertSharedChannelCancels(stale, appState))

        try await waitUntil("App, Find, and the hosted editor rekey to renamed.md") {
            let identity = appState.activeEditorDocumentIdentity
            return appState.currentDocument.fileURL?.lastPathComponent == "renamed.md"
                && identity != originalIdentity
                && appState.editorFindHost.controller.documentBinding.identity == identity
                && self.editorIdentity(in: window) == identity
                && appState.editorFindHost.controller.session?.total == 2
        }
        let renamedIdentity = try XCTUnwrap(appState.activeEditorDocumentIdentity)
        try await assertFindBarStayedMounted(
            field,
            query: "hit",
            selection: ranges[0],
            appState: appState,
            window: window
        )
        try await assertPreTransitionNavigationCannotLand(
            stale,
            retargetedAt: renamedIdentity,
            cancelID: cancelID,
            appState: appState,
            window: window,
            selection: ranges[0]
        )

        // The channel is still live for work started after the rename.
        appState.handleEditorFindQueryTextChange("two")
        let two = (source as NSString).range(of: "two")
        try await waitUntil("a post-rename query navigates the renamed document") {
            self.appliedRange(in: window) == two
                && self.editorIdentity(in: window) == renamedIdentity
        }
    }

    func testHostedDetachedSaveCopyRekeysFindWithoutAutoJumpAndCancelsAPublishedNavigation() async throws {
        let source = "hit one hit two"
        let fixture = try makeWorkspaceFixture(files: ["post.md": source])
        let appState = fixture.appState
        let detached = try await openDetachedFindFixture(fixture, source: source)
        let (window, field, ranges) = (detached.host.window, detached.field, detached.ranges)
        let destination = fixture.root.appendingPathComponent("recovered.md")

        let stale = try publishFindStep(appState, expecting: ranges[1])
        try appState.saveDetachedCurrentDocument(to: destination)
        let cancelID = try XCTUnwrap(assertSharedChannelCancels(stale, appState))

        let expectedIdentity = AppState.editorDocumentIdentity(for: destination.standardizedFileURL)
        try await waitUntil("App, Find, and the hosted editor follow the Save Copy destination") {
            appState.currentDocument.fileURL?.standardizedFileURL == destination.standardizedFileURL
                && appState.missingFilePrompt == nil
                && appState.activeEditorDocumentIdentity == expectedIdentity
                && appState.editorFindHost.controller.documentBinding.identity == expectedIdentity
                && self.editorIdentity(in: window) == expectedIdentity
                && appState.editorFindHost.controller.session?.total == 2
        }
        try await assertFindBarStayedMounted(
            field,
            query: "hit",
            selection: ranges[0],
            appState: appState,
            window: window
        )
        try await assertPreTransitionNavigationCannotLand(
            stale,
            retargetedAt: expectedIdentity,
            cancelID: cancelID,
            appState: appState,
            window: window,
            selection: ranges[0]
        )

        appState.handleEditorFindQueryTextChange("two")
        let two = (source as NSString).range(of: "two")
        try await waitUntil("a post-Save-Copy query navigates the destination document") {
            self.appliedRange(in: window) == two
                && self.editorIdentity(in: window) == expectedIdentity
        }
    }

    func testHostedIndeterminateSaveCopyQuarantineRekeysFindAndCancelsAPublishedNavigation() async throws {
        let source = "hit one hit two"
        let fixture = try makeWorkspaceFixture(files: ["post.md": source])
        let appState = fixture.appState
        let detached = try await openDetachedFindFixture(fixture, source: source)
        let (window, field, ranges) = (detached.host.window, detached.field, detached.ranges)
        let destination = fixture.root.appendingPathComponent("recovered.md")

        // The destination commits, but its durability cannot be proven: production rehomes the
        // session to the quarantined destination instead of the missing original.
        appState.anchoredFileSaveOverride = { text, location, _ in
            let actual = try MarkdownFileStore().save(text: text, at: location, expecting: .missing)
            guard case let .committedAndDurable(durable) = actual else {
                XCTFail("Expected a deterministic destination commit")
                return actual
            }
            return .committedButIndeterminate(
                WorkspaceIndeterminateFileWrite(
                    reason: .durabilityFailed,
                    preparedMetadata: durable.metadata,
                    recoveryArtifact: .retained(location)
                )
            )
        }

        let stale = try publishFindStep(appState, expecting: ranges[1])
        XCTAssertThrowsError(try appState.saveDetachedCurrentDocument(to: destination))
        let cancelID = try XCTUnwrap(assertSharedChannelCancels(stale, appState))

        let expectedIdentity = AppState.editorDocumentIdentity(for: destination.standardizedFileURL)
        try await waitUntil("App, Find, and the hosted editor follow the quarantined destination") {
            appState.currentDocument.fileURL?.standardizedFileURL == destination.standardizedFileURL
                && appState.activeEditorDocumentIdentity == expectedIdentity
                && appState.editorFindHost.controller.documentBinding.identity == expectedIdentity
                && self.editorIdentity(in: window) == expectedIdentity
                && appState.editorFindHost.controller.session?.total == 2
        }
        XCTAssertNotNil(
            appState.indeterminateSessionWriteContexts[ObjectIdentifier(appState.currentDocument)]
        )
        try await assertFindBarStayedMounted(
            field,
            query: "hit",
            selection: ranges[0],
            appState: appState,
            window: window
        )
        try await assertPreTransitionNavigationCannotLand(
            stale,
            retargetedAt: expectedIdentity,
            cancelID: cancelID,
            appState: appState,
            window: window,
            selection: ranges[0]
        )
    }

    func testHostedExternalReloadDropsAFindNavigationStillComputingBeforeIt() async throws {
        let source = "hit one hit two"
        let fixture = try makeWorkspaceFixture(files: ["post.md": source])
        let appState = fixture.appState
        appState.setLayoutMode(.sourceOnly)
        appState.openExternalFile(fixture.root)
        try await waitUntil("workspace document opens") {
            appState.currentDocument.fileURL?.lastPathComponent == "post.md"
        }
        let host = makeWorkspaceHost(appState: appState)
        registerTeardown(host: host, fixture: fixture)
        let window = host.window
        let ranges = matchRanges(of: "hit", in: source)
        let controller = appState.editorFindHost.controller

        openFindBar(appState, query: "hit")
        try await waitUntil("find selects the first match in the hosted editor") {
            self.appliedRange(in: window) == ranges[0] && controller.session?.total == 2
        }
        let field = try XCTUnwrap(findQueryField(in: window))

        // A re-typed query and a ⌘G are both still computing when Reload lands. Unfenced,
        // that generation would navigate to the second match after Reload.
        let hold = EditorFindMatchHold()
        controller.testMatchHold = hold
        defer { hold.release() }
        appState.handleEditorFindQueryTextChange("hit")
        appState.stepEditorFindFromBarControl(.next)
        XCTAssertNil(controller.session, "the pre-Reload generation must still be in flight")
        let channelBefore = try XCTUnwrap(appState.editorNavigationCommand?.id)
        let droppedBefore = controller.droppedStaleMatchCount

        let reloaded = "hit one hit two hit three"
        let post = fixture.root.appendingPathComponent("post.md")
        try reloaded.write(to: post, atomically: true, encoding: .utf8)
        appState.refreshWorkspaceAfterFileSystemChange()
        try await waitUntil("clean Reload reaches App and the hosted editor") {
            appState.currentDocument.text == reloaded
                && self.editorTextView(in: window)?.text == reloaded
        }
        guard case let .cancel(cancelID)? = appState.editorNavigationCommand else {
            return XCTFail("Reload must fence Find with a cancel on the shared channel")
        }
        XCTAssertGreaterThan(cancelID, channelBefore)
        let afterReload = try XCTUnwrap(appliedRange(in: window))
        XCTAssertNotEqual(afterReload, ranges[1], "precondition: a stale landing must be observable")

        hold.release()
        try await waitUntil("counter recounts against the reloaded text") {
            controller.session?.total == 3
        }
        XCTAssertGreaterThan(
            controller.droppedStaleMatchCount,
            droppedBefore,
            "the pre-Reload generation must be fence-dropped, not applied"
        )
        try await assertFindBarStayedMounted(
            field,
            query: "hit",
            selection: afterReload,
            appState: appState,
            window: window
        )
        XCTAssertNil(controller.pendingNavigationCommand)
        XCTAssertNil(try XCTUnwrap(editorCoordinator(in: window)).navigationState.pendingRequest)
    }

    func testHostedMissingFileCloseCancelsAPublishedNavigationAndUnmountsTheBar() async throws {
        let source = "hit one hit two"
        let fixture = try makeWorkspaceFixture(files: ["post.md": source])
        let appState = fixture.appState
        let detached = try await openDetachedFindFixture(fixture, source: source)
        let (window, ranges) = (detached.host.window, detached.ranges)

        let stale = try publishFindStep(appState, expecting: ranges[1])
        appState.closeMissingFile()
        assertSharedChannelCancels(stale, appState)

        try await waitUntil("closing the missing file unmounts the bar and the editor") {
            !appState.hasOpenDocument
                && !appState.editorFindHost.ui.isBarVisible
                && self.findQueryField(in: window) == nil
                && self.editorTextView(in: window) == nil
        }
        XCTAssertNil(appState.editorFindHost.controller.query)
        XCTAssertNil(appState.editorFindHost.controller.session)
        XCTAssertNil(appState.editorFindHost.controller.pendingNavigationCommand)
    }

    /// Opens `post.md` in a hosted workspace with Find on its first match, then deletes the
    /// file so the missing-file banner is showing above the still-mounted bar.
    private func openDetachedFindFixture(
        _ fixture: WorkspaceFixture,
        source: String
    ) async throws -> DetachedFindFixture {
        let appState = fixture.appState
        appState.setLayoutMode(.sourceOnly)
        appState.openExternalFile(fixture.root)
        try await waitUntil("workspace document opens") {
            appState.currentDocument.fileURL?.lastPathComponent == "post.md"
        }
        let host = makeWorkspaceHost(appState: appState)
        registerTeardown(host: host, fixture: fixture)
        let ranges = matchRanges(of: "hit", in: source)

        openFindBar(appState, query: "hit")
        try await waitUntil("find selects the first match in the hosted editor") {
            self.appliedRange(in: host.window) == ranges[0]
                && appState.editorFindHost.controller.session?.total == 2
        }
        let field = try XCTUnwrap(findQueryField(in: host.window))

        // The test drives the refresh the FSEvents watcher would drive. Stopping the watcher
        // keeps its debounced duplicate from advancing the workspace capture generation in
        // the middle of the transition under test (Save Copy refuses an unsettled capture).
        appState.workspaceWatcher?.stop()
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("post.md"))
        appState.refreshWorkspaceAfterFileSystemChange()
        // Save Copy (like the banner button) acts once the workspace capture has settled.
        try await waitUntil("missing-file banner appears and the workspace capture settles") {
            appState.missingFilePrompt?.fileURL.lastPathComponent == "post.md"
                && appState.workspaceInstalledCaptureGeneration == appState.workspaceGeneration
        }
        XCTAssertTrue(findQueryField(in: host.window) === field)
        XCTAssertEqual(appliedRange(in: host.window), ranges[0])
        return DetachedFindFixture(host: host, field: field, ranges: ranges)
    }
}

struct DetachedFindFixture {
    let host: HostedWorkspace
    let field: NSTextField
    let ranges: [NSRange]
}
