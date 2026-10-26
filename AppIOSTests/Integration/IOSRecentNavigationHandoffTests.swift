import EditorKitIOS
import Foundation
@testable import PlainsongIOS
import PreviewKit
import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSRecentNavigationHandoffTests: XCTestCase {
    func testPickedURLWaitsForCancelledRecentRestoreAndOpensWithoutASecondWriter() async throws {
        let fixture = IOSRecentSceneFixture()
        let id = fixture.access.add(scope: .singleFile)
        let latch = IOSSceneControllerLatch()
        defer { latch.release() }
        fixture.access.restoreLatch = latch
        let recent = Task { try await fixture.controller.openRecent(recordID: id, using: fixture.access) }
        try await waitUntil { fixture.access.restoredGrant != nil }
        let abandoned = try XCTUnwrap(fixture.access.restoredGrant)
        recent.cancel()
        let target = URL(fileURLWithPath: "/synthetic/picked.md")
        let picked = Task { try await fixture.controller.openPickedURL(target, scope: .singleFile) }
        try await waitUntil { fixture.controller.pendingRecentNavigation != nil }
        XCTAssertTrue(fixture.access.workspace.base.selected.isEmpty)
        XCTAssertTrue(fixture.store.opened.isEmpty)
        latch.release()
        await assertCancelled(recent)
        try await picked.value
        XCTAssertEqual(fixture.store.opened.map(\.fileURL), [target])
        XCTAssertEqual(fixture.controller.handle?.location.fileURL, target)
        XCTAssertTrue(fixture.access.workspace.base.invalidated.contains(abandoned.workspaceID))
        XCTAssertTrue(fixture.editor.snapshot.canWrite)
    }

    func testLatestSceneURLSupersedesOnlyTheOlderPendingRequest() async throws {
        let fixture = IOSRecentSceneFixture()
        let id = fixture.access.add(scope: .singleFile)
        let latch = IOSSceneControllerLatch()
        defer { latch.release() }
        fixture.access.restoreLatch = latch
        let recent = Task { try await fixture.controller.openRecent(recordID: id, using: fixture.access) }
        try await waitUntil { fixture.access.restoredGrant != nil }
        let oldURL = URL(fileURLWithPath: "/synthetic/superseded.md")
        let latestURL = URL(fileURLWithPath: "/synthetic/latest.md")
        let first = Task { try await fixture.controller.openPickedURL(oldURL, scope: .singleFile) }
        try await waitUntil { fixture.controller.pendingRecentNavigation != nil }
        let firstID = fixture.controller.pendingRecentNavigation?.id
        let latest = Task { try await fixture.controller.openPickedURL(latestURL, scope: .singleFile) }
        try await waitUntil { fixture.controller.pendingRecentNavigation?.id != firstID }
        await assertCancelled(first)
        XCTAssertTrue(fixture.access.workspace.base.selected.isEmpty)
        latch.release()
        await assertCancelled(recent)
        try await latest.value
        XCTAssertEqual(fixture.access.workspace.base.selected.map(\.0), [latestURL])
        XCTAssertEqual(fixture.store.opened.map(\.fileURL), [latestURL])
    }

    func testFilesFacadeSelectionWaitsForRecentDrainAndUsesTheOriginalLiveGrant() async throws {
        let fixture = IOSRecentSceneFixture()
        let root = URL(fileURLWithPath: "/synthetic/folder", isDirectory: true)
        try await fixture.controller.openPickedURL(root, scope: .directory)
        let originalGrant = try XCTUnwrap(fixture.controller.currentGrant)
        let entry = try XCTUnwrap(fixture.controller.snapshot.workspace?.entries.last)
        let scene = IOSShellSceneState(facade: fixture.controller)
        scene.startObserving()
        defer { scene.stopObserving() }
        let id = fixture.access.add(scope: .singleFile)
        let latch = IOSSceneControllerLatch()
        defer { latch.release() }
        fixture.access.restoreLatch = latch
        let recent = Task { try await fixture.controller.openRecent(recordID: id, using: fixture.access) }
        try await waitUntil { fixture.access.restoredGrant != nil }
        scene.openEntry(entry)
        try await waitUntil { fixture.controller.pendingRecentNavigation != nil }
        latch.release()
        await assertCancelled(recent)
        try await waitUntil { fixture.controller.handle?.location.fileURL == entry.location.fileURL }
        XCTAssertEqual(fixture.controller.currentGrant?.workspaceID, originalGrant.workspaceID)
        XCTAssertEqual(fixture.access.workspace.base.selected.count, 1)
        XCTAssertFalse(fixture.access.workspace.base.invalidated.contains(originalGrant.workspaceID))
        XCTAssertTrue(fixture.editor.snapshot.canWrite)
        XCTAssertNil(scene.presentedError)
    }

    func testCancelledInstallSafelyClosesTheReturnedWriterBeforeReleasingItsGrant() async throws {
        let fixture = IOSRecentSceneFixture()
        let id = fixture.access.add(scope: .singleFile)
        let latch = IOSSceneControllerLatch()
        defer { latch.release() }
        fixture.store.openLatch = latch
        let recent = Task { try await fixture.controller.openRecent(recordID: id, using: fixture.access) }
        try await waitUntil { fixture.store.opened.count == 1 }
        let grant = try XCTUnwrap(fixture.controller.currentGrant)
        recent.cancel()
        latch.release()
        await assertCancelled(recent)
        XCTAssertEqual(fixture.store.closed.count, 1)
        XCTAssertNil(fixture.controller.handle)
        XCTAssertNil(fixture.controller.admission.active)
        XCTAssertNil(fixture.controller.currentGrant)
        XCTAssertNil(fixture.editor.captureSnapshot())
        XCTAssertTrue(fixture.access.workspace.base.invalidated.contains(grant.workspaceID))
    }

    func testFilesSelectionDuringInstallSafelyReopensOnlyThroughItsStillLiveGrant() async throws {
        let fixture = IOSRecentSceneFixture()
        let id = fixture.access.add(scope: .singleFile)
        let latch = IOSSceneControllerLatch()
        defer { latch.release() }
        fixture.store.openLatch = latch
        let recent = Task { try await fixture.controller.openRecent(recordID: id, using: fixture.access) }
        try await waitUntil { fixture.store.opened.count == 1 }
        let grant = try XCTUnwrap(fixture.controller.currentGrant)
        let selected = Task { try await fixture.controller.openSelectedURL(grant.rootURL, scope: .singleFile) }
        try await waitUntil { fixture.controller.pendingRecentNavigation != nil }
        latch.release()
        await assertCancelled(recent)
        try await selected.value
        XCTAssertEqual(fixture.store.closed.count, 1)
        XCTAssertEqual(fixture.store.opened.count, 2)
        XCTAssertEqual(fixture.controller.currentGrant?.workspaceID, grant.workspaceID)
        XCTAssertFalse(fixture.access.workspace.base.invalidated.contains(grant.workspaceID))
        XCTAssertTrue(fixture.access.workspace.base.selected.isEmpty)
        XCTAssertTrue(fixture.editor.snapshot.canWrite)
    }

    func testRetainedCancelledWriterRefusesQueuedReplacementWithoutNewAuthority() async throws {
        let fixture = IOSRecentSceneFixture()
        let id = fixture.access.add(scope: .singleFile)
        let latch = IOSSceneControllerLatch()
        defer { latch.release() }
        fixture.store.openLatch = latch
        let recent = Task { try await fixture.controller.openRecent(recordID: id, using: fixture.access) }
        try await waitUntil { fixture.store.opened.count == 1 }
        fixture.store.closeOutcome = .retained(recovery: nil)
        let replacement = Task {
            try await fixture.controller.openPickedURL(
                URL(fileURLWithPath: "/synthetic/refused.md"),
                scope: .singleFile
            )
        }
        try await waitUntil { fixture.controller.pendingRecentNavigation != nil }
        latch.release()
        for operation in [recent, replacement] {
            do {
                try await operation.value
                XCTFail("A retained writer cannot be dropped for a queued URL")
            } catch {
                XCTAssertEqual(error as? IOSDocumentFailure, .closeFailed)
            }
        }
        let handle = try XCTUnwrap(fixture.controller.handle)
        XCTAssertEqual(fixture.controller.admission.active?.documentID, handle.identity)
        XCTAssertTrue(fixture.editor.binding.session === handle.session)
        XCTAssertFalse(fixture.editor.snapshot.canWrite)
        XCTAssertEqual(fixture.store.opened.count, 1)
        XCTAssertTrue(fixture.access.workspace.base.selected.isEmpty)
    }

    func testRevokedInstallCannotUseAQueuedFilesURLToReviveItsGrant() async throws {
        let fixture = IOSRecentSceneFixture()
        let id = fixture.access.add(scope: .singleFile)
        let latch = IOSSceneControllerLatch()
        defer { latch.release() }
        fixture.store.openLatch = latch
        let recent = Task { try await fixture.controller.openRecent(recordID: id, using: fixture.access) }
        try await waitUntil { fixture.store.opened.count == 1 }
        let grant = try XCTUnwrap(fixture.controller.currentGrant)
        let selected = Task { try await fixture.controller.openSelectedURL(grant.rootURL, scope: .singleFile) }
        try await waitUntil { fixture.controller.pendingRecentNavigation != nil }
        _ = fixture.access.workspace.invalidate(grant.workspaceID)
        latch.release()
        do {
            try await recent.value
            XCTFail("A revoked install must not complete")
        } catch {
            XCTAssertEqual(error as? IOSWorkspaceFailure, .grantChanged)
        }
        do {
            try await selected.value
            XCTFail("A queued Files URL has no authority after revocation")
        } catch {
            XCTAssertEqual(error as? IOSDocumentFailure, .access(.outsideGrant))
        }
        let handle = try XCTUnwrap(fixture.controller.handle)
        XCTAssertEqual(fixture.controller.admission.active?.documentID, handle.identity)
        XCTAssertFalse(fixture.controller.grantIsCurrent)
        XCTAssertFalse(fixture.editor.snapshot.canWrite)
        XCTAssertEqual(fixture.store.opened.count, 1)
        XCTAssertTrue(fixture.access.workspace.base.selected.isEmpty)
    }

    func testCancelledQueuedURLDoesNotMintAReplacementGrantOrReopenAWriter() async throws {
        let fixture = IOSRecentSceneFixture()
        let id = fixture.access.add(scope: .singleFile)
        let latch = IOSSceneControllerLatch()
        defer { latch.release() }
        fixture.access.restoreLatch = latch
        let recent = Task { try await fixture.controller.openRecent(recordID: id, using: fixture.access) }
        try await waitUntil { fixture.access.restoredGrant != nil }
        let queued = Task {
            try await fixture.controller.openPickedURL(
                URL(fileURLWithPath: "/synthetic/cancelled.md"),
                scope: .singleFile
            )
        }
        try await waitUntil { fixture.controller.pendingRecentNavigation != nil }
        queued.cancel()
        await assertCancelled(queued)
        XCTAssertNil(fixture.controller.pendingRecentNavigation)
        latch.release()
        await assertCancelled(recent)
        XCTAssertTrue(fixture.access.workspace.base.selected.isEmpty)
        XCTAssertTrue(fixture.store.opened.isEmpty)
        XCTAssertNil(fixture.controller.admission.active)
    }

    func testRuntimePickerAndLatestOSURLSurviveACancelledRecentProviderDrain() async throws {
        try await runRuntimeHandoff(cancelPicker: false)
    }

    func testCancelledPickerCallerCannotCancelTheLatestQueuedOSDelivery() async throws {
        try await runRuntimeHandoff(cancelPicker: true)
    }

    func testShutdownRefusesAPendingURLAfterRecentInstallDrains() async throws {
        let fixture = IOSRecentSceneFixture()
        let id = fixture.access.add(scope: .singleFile)
        let latch = IOSSceneControllerLatch()
        defer { latch.release() }
        fixture.store.openLatch = latch
        let recent = Task { try await fixture.controller.openRecent(recordID: id, using: fixture.access) }
        try await waitUntil { fixture.store.opened.count == 1 }
        let queued = Task {
            try await fixture.controller.openPickedURL(URL(fileURLWithPath: "/synthetic/after-shutdown.md"),
                                                       scope: .singleFile)
        }
        try await waitUntil { fixture.controller.pendingRecentNavigation != nil }
        let shutdown = Task { await fixture.controller.shutdown() }
        try await waitUntil { fixture.controller.isShuttingDown }
        latch.release()
        await assertCancelled(recent)
        do {
            try await queued.value
            XCTFail("A pending URL cannot create authority during shutdown")
        } catch {
            XCTAssertEqual(error as? IOSDocumentFailure, .unavailable)
        }
        let closed = await shutdown.value
        XCTAssertTrue(closed)
        XCTAssertTrue(fixture.controller.isDisposed)
        XCTAssertNil(fixture.controller.handle)
        XCTAssertNil(fixture.controller.admission.active)
        XCTAssertEqual(fixture.store.closed.count, 1)
        XCTAssertTrue(fixture.access.workspace.base.selected.isEmpty)
    }

    private func runRuntimeHandoff(cancelPicker: Bool) async throws {
        let access = IOSRecentTestAccess()
        let store = IOSSceneControllerStoreDouble()
        let editor = IOSSourceEditorController()
        let preview = PreviewController()
        let assets = IOSWorkspaceAccessFactory.makeProduction(recentKey: "RecentHandoff.\(UUID())")
        let controller = IOSDocumentSceneController(documents: store, workspace: access.workspace, editor: editor,
                                                    preview: preview, assets: assets, assetContext: { _ in nil })
        let runtime = try IOSProductionRuntime(
            controller: controller, editor: editor, preview: preview,
            currentGrant: { controller.currentGrant }, refreshWorkspace: { try await controller.refreshWorkspace() },
            openPickedURL: { try await controller.openPickedURL($0, scope: $1) },
            shutdown: { await controller.shutdown() }
        )
        runtime.recentPresentation.install(access: access, openRecent: {
            try await controller.openRecent(recordID: $0, using: access)
        }, reselectionScope: { .singleFile })
        addTeardownBlock { @MainActor in
            runtime.stopObserving()
            runtime.scene.stopObserving()
            let closed = await runtime.shutdown()
            XCTAssertTrue(closed)
        }
        let id = access.add(scope: .singleFile)
        let latch = IOSSceneControllerLatch()
        defer { latch.release() }
        access.restoreLatch = latch
        runtime.recentPresentation.present()
        let presentationID = try XCTUnwrap(runtime.recentPresentation.presentationID)
        XCTAssertTrue(runtime.recentPresentation.didAppear(presentationID))
        let presenter = try XCTUnwrap(runtime.recentPresentation.presenter)
        presenter.open(recordID: id)
        try await waitUntil { access.restoredGrant != nil }
        runtime.requestPicker(scope: .singleFile)
        runtime.recentPresentation.didDismiss(presentationID)
        let request = try XCTUnwrap(runtime.pickerRequest)
        let pickedURL = URL(fileURLWithPath: "/synthetic/picker-handoff.md")
        let pickerOpen = try XCTUnwrap(runtime.completePicker(request, urls: [pickedURL]))
        try await waitUntil { controller.pendingRecentNavigation != nil }
        let supersededOSURL = URL(fileURLWithPath: "/synthetic/superseded-OS.md")
        let finalOSURL = URL(fileURLWithPath: "/synthetic/final-OS.md")
        await runtime.openURL(supersededOSURL)
        await runtime.openURL(finalOSURL)
        if cancelPicker {
            pickerOpen.cancel()
        }
        XCTAssertTrue(runtime.isOpening)
        XCTAssertTrue(access.workspace.base.selected.isEmpty)
        latch.release()
        await pickerOpen.value
        try await waitUntil { !presenter.isBusy }
        XCTAssertFalse(runtime.isOpening)
        let expected = cancelPicker ? [finalOSURL] : [pickedURL, finalOSURL]
        XCTAssertEqual(access.workspace.base.selected.map(\.0), expected)
        XCTAssertEqual(store.opened.map(\.fileURL), expected)
        XCTAssertEqual(controller.handle?.location.fileURL, finalOSURL)
        XCTAssertTrue(editor.captureSnapshot()?.canWrite == true)
        XCTAssertNil(runtime.scene.presentedError)
        runtime.recentPresentation.didDismiss(presentationID)
        XCTAssertNil(runtime.pickerRequest)
    }

    private func assertCancelled(_ task: Task<Void, Error>, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await task.value
            XCTFail("Superseded/cancelled operation must not report completion", file: file, line: line)
        } catch {
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0 ..< 200 {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Recent navigation did not reach the expected suspension or installation")
        throw IOSDocumentFailure.unavailable
    }
}
