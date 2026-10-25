import EditorKitIOS
import Foundation
import MarkdownCore
@testable import PlainsongIOS
import PreviewKit
import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSRecentPresentationTests: XCTestCase {
    func testChooseAgainWaitsForActualDismissalAndConsumesTheCapturedScopeOnce() throws {
        let access = IOSRecentTestAccess()
        let recordID = access.add(scope: .directory, status: .needsReselection)
        let runtime = try makeRuntime(access: access)
        let presentationID = try present(runtime)
        let presenter = try XCTUnwrap(runtime.recentPresentation.presenter)
        presenter.chooseAgain(recordID: recordID)
        XCTAssertFalse(runtime.recentPresentation.isPresented)
        XCTAssertTrue(runtime.recentPresentation.isActive)
        XCTAssertNil(runtime.pickerRequest)
        runtime.recentPresentation.didDismiss(presentationID)
        let request = try XCTUnwrap(runtime.pickerRequest)
        XCTAssertEqual(request.scope, .directory)
        runtime.recentPresentation.didDismiss(presentationID)
        XCTAssertEqual(runtime.pickerRequest?.id, request.id)
        XCTAssertTrue(access.restoreCalls.isEmpty)
    }

    func testOSOpenRetiresPendingRecentPickerAndLateDismissalCannotOverrideIt() async throws {
        let access = IOSRecentTestAccess()
        let recordID = access.add(scope: .directory, status: .needsReselection)
        var opened: [URL] = []
        let runtime = try makeRuntime(access: access, openPicked: { url, _ in opened.append(url) })
        let presentationID = try present(runtime)
        try XCTUnwrap(runtime.recentPresentation.presenter).chooseAgain(recordID: recordID)
        let delivered = URL(fileURLWithPath: "/synthetic/OS-open.md")
        await runtime.openURL(delivered)
        runtime.recentPresentation.didDismiss(presentationID)
        XCTAssertEqual(opened, [delivered])
        XCTAssertNil(runtime.pickerRequest)
        XCTAssertFalse(runtime.recentPresentation.isActive)
    }

    func testCancelledUnpresentedRequestCannotBlockOrRetireANewerPresentation() throws {
        let access = IOSRecentTestAccess()
        let runtime = try makeRuntime(access: access)
        runtime.recentPresentation.present()
        let oldID = try XCTUnwrap(runtime.recentPresentation.presentationID)
        runtime.recentPresentation.cancel()
        XCTAssertFalse(runtime.recentPresentation.isActive)
        let newID = try present(runtime)
        XCTAssertNotEqual(oldID, newID)
        XCTAssertFalse(runtime.recentPresentation.didAppear(oldID))
        runtime.recentPresentation.didDismiss(oldID)
        XCTAssertEqual(runtime.recentPresentation.presentationID, newID)
        XCTAssertTrue(runtime.recentPresentation.isPresented)
        runtime.recentPresentation.isPresented = false
        runtime.recentPresentation.didDismiss(newID)
        XCTAssertFalse(runtime.recentPresentation.isActive)
    }

    func testSuccessfulRecentNavigationWaitsForDismissalAndDirectoryReturnsToFiles() async throws {
        for scope in [IOSWorkspaceScope.singleFile, .directory] {
            let access = IOSRecentTestAccess()
            let recordID = access.add(scope: scope)
            let runtime = try makeRuntime(access: access)
            let initial: [IOSShellRoute] = scope == .directory ? [.document] : []
            runtime.scene.navigationPath = initial
            let presentationID = try present(runtime)
            let presenter = try XCTUnwrap(runtime.recentPresentation.presenter)
            presenter.open(recordID: recordID)
            try await waitUntil { !presenter.isBusy && !runtime.recentPresentation.isPresented }
            XCTAssertEqual(runtime.scene.navigationPath, initial)
            runtime.recentPresentation.didDismiss(presentationID)
            XCTAssertEqual(runtime.scene.navigationPath, scope == .singleFile ? [.document] : [])
        }
    }

    func testExternalPickerCancelsParkedRecentAndSuppressesLateNavigation() async throws {
        let access = IOSRecentTestAccess()
        let recordID = access.add(scope: .singleFile)
        let latch = IOSSceneControllerLatch()
        let started = expectation(description: "Recent open parked")
        let runtime = try makeRuntime(access: access, openRecent: { _ in
            started.fulfill()
            await latch.wait()
        })
        let presentationID = try present(runtime)
        let presenter = try XCTUnwrap(runtime.recentPresentation.presenter)
        presenter.open(recordID: recordID)
        await fulfillment(of: [started], timeout: 2)
        runtime.requestPicker(scope: .directory)
        XCTAssertTrue(presenter.isBusy)
        XCTAssertNil(runtime.pickerRequest)
        runtime.recentPresentation.didDismiss(presentationID)
        XCTAssertEqual(runtime.pickerRequest?.scope, .directory)
        latch.release()
        try await waitUntil { !presenter.isBusy }
        XCTAssertTrue(runtime.scene.navigationPath.isEmpty)
        XCTAssertNil(presenter.errorMessage)
    }

    func testUnavailableReselectionPreservesNativeSourceAndUsesTheCapturedFolderScope() throws {
        let access = IOSRecentTestAccess()
        var opened = 0
        let runtime = try makeRuntime(access: access, openPicked: { _, _ in opened += 1 })
        let facade = try XCTUnwrap(runtime.controller as? FakeSceneFacade)
        let identity = IOSDocumentIdentity(rawValue: UUID())
        let bindingID = UUID()
        let session = DocumentSession(text: "Unsaved 繁中 source", fileKind: .markdown, isDirty: true)
        let state = IOSDocumentState.unavailable(accessGeneration: 7, reason: .access(.permissionDenied))
        runtime.editor.attach(IOSSourceEditorDocumentBinding(
            bindingID: bindingID, identity: identity, session: session, accessGeneration: 7, canWrite: false
        ))
        facade.emit(IOSAppSceneSnapshot(
            document: IOSStoredDocumentSnapshot(
                revision: IOSDocumentRevision(documentID: identity, version: session.version),
                document: session.snapshot, location: ShellFixtures.location("unsaved.md"), state: state
            ), documentState: state, workspace: nil, unavailableReason: "Access revoked"
        ))
        runtime.scene.startObserving()
        let undo = runtime.editor.textView.undoManager
        runtime.scene.reselectUnavailableDocument()
        let request = try XCTUnwrap(runtime.pickerRequest)
        XCTAssertEqual(request.scope, .directory)
        XCTAssertNil(runtime.completePicker(request, urls: []))
        XCTAssertEqual(opened, 0)
        XCTAssertTrue(facade.openedURLs.isEmpty)
        XCTAssertEqual(session.text, "Unsaved 繁中 source")
        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(runtime.editor.captureSnapshot()?.bindingID, bindingID)
        XCTAssertEqual(runtime.editor.textView.text, session.text)
        XCTAssertTrue(runtime.editor.textView.undoManager === undo)
    }

    private func makeRuntime(
        access: IOSRecentTestAccess,
        openRecent: @escaping @MainActor (UUID) async throws -> Void = { _ in },
        openPicked: @escaping @MainActor (URL, IOSWorkspaceScope) async throws -> Void = { _, _ in }
    ) throws -> IOSProductionRuntime {
        let editor = IOSSourceEditorController()
        let preview = PreviewController()
        let assets = IOSWorkspaceAccessFactory.makeProduction(recentKey: "RecentPresentation.\(UUID())")
        let facade = FakeSceneFacade(capabilities: IOSSceneCapabilities(
            editor: editor, documents: nil, workspace: access.workspace, preview: preview, assets: assets
        ))
        let runtime = try IOSProductionRuntime(
            controller: facade, editor: editor, preview: preview,
            currentGrant: { nil }, refreshWorkspace: {}, openPickedURL: openPicked, shutdown: { true }
        )
        runtime.recentPresentation.install(access: access, openRecent: openRecent, reselectionScope: { .directory })
        addTeardownBlock { @MainActor in
            runtime.stopObserving()
            runtime.scene.stopObserving()
            preview.invalidate()
        }
        return runtime
    }

    private func present(_ runtime: IOSProductionRuntime) throws -> UUID {
        try XCTUnwrap(runtime.scene.surfaces.showRecentWorkspaces)()
        let id = try XCTUnwrap(runtime.recentPresentation.presentationID)
        XCTAssertTrue(runtime.recentPresentation.didAppear(id))
        return id
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0 ..< 100 {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Recent presentation did not settle")
        throw IOSDocumentFailure.unavailable
    }
}
