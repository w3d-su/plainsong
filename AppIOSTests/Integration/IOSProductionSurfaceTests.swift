import EditorKitIOS
import Foundation
import MarkdownCore
@testable import PlainsongIOS
import PreviewKit
import UIKit
import UniformTypeIdentifiers
import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSProductionSurfaceTests: XCTestCase {
    func testFileAndDirectoryPickersNeverMixAuthority() {
        let file = IOSProductionPickerRequest(scope: .singleFile)
        let directory = IOSProductionPickerRequest(scope: .directory)
        XCTAssertFalse(file.contentTypes.contains(.folder))
        XCTAssertEqual(directory.contentTypes, [.folder])
        XCTAssertNotEqual(file.id, directory.id)
    }

    func testPickerDelegateDeliversOnlyOneTerminalResult() {
        var deliveries: [[URL]] = []
        let coordinator = IOSProductionDocumentPicker.Coordinator { deliveries.append($0) }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.plainText], asCopy: false)
        let selected = URL(fileURLWithPath: "/tmp/selected.md")
        coordinator.documentPicker(picker, didPickDocumentsAt: [selected])
        coordinator.documentPickerWasCancelled(picker)
        coordinator.documentPicker(picker, didPickDocumentsAt: [selected])
        XCTAssertEqual(deliveries, [[selected]])
    }

    func testCancelledPickerDoesNotOpenOrNavigate() throws {
        var opened = false
        let harness = try makeHarness { _, _ in opened = true }
        harness.runtime.requestPicker(scope: .singleFile)
        let request = try XCTUnwrap(harness.runtime.pickerRequest)
        XCTAssertNil(harness.runtime.completePicker(request, urls: []))
        XCTAssertFalse(opened)
        XCTAssertFalse(harness.runtime.isOpening)
        XCTAssertTrue(harness.runtime.scene.navigationPath.isEmpty)
        XCTAssertTrue(harness.facade.openedURLs.isEmpty)
    }

    func testStalePickerCompletionCannotOpenTheNextIssuance() throws {
        var opened = false
        let harness = try makeHarness { _, _ in opened = true }
        harness.runtime.requestPicker(scope: .singleFile)
        let old = try XCTUnwrap(harness.runtime.pickerRequest)
        _ = harness.runtime.completePicker(old, urls: [])
        harness.runtime.requestPicker(scope: .directory)
        let current = try XCTUnwrap(harness.runtime.pickerRequest)
        XCTAssertNil(harness.runtime.completePicker(old, urls: [URL(fileURLWithPath: "/tmp/old.md")]))
        XCTAssertEqual(harness.runtime.pickerRequest?.id, current.id)
        XCTAssertFalse(opened)
    }

    func testFileNavigationFollowsSuccessfulExplicitOpen() async throws {
        var facade: FakeSceneFacade?
        var runtime: IOSProductionRuntime?
        let harness = try makeHarness { _, scope in
            XCTAssertEqual(scope, .singleFile)
            XCTAssertTrue(runtime?.scene.navigationPath.isEmpty == true)
            facade?.snapshot = IOSAppSceneSnapshot(
                document: ShellFixtures.storedDocument(), documentState: nil,
                workspace: nil, unavailableReason: nil
            )
        }
        facade = harness.facade
        runtime = harness.runtime
        harness.runtime.requestPicker(scope: .singleFile)
        let request = try XCTUnwrap(harness.runtime.pickerRequest)
        let task = try XCTUnwrap(harness.runtime.completePicker(request, urls: [URL(fileURLWithPath: "/tmp/post.md")]))
        XCTAssertTrue(harness.runtime.isOpening)
        XCTAssertTrue(harness.runtime.scene.navigationPath.isEmpty)
        await task.value
        XCTAssertEqual(harness.runtime.scene.navigationPath, [.document])
        XCTAssertFalse(harness.runtime.isOpening)
        XCTAssertTrue(
            harness.facade.openedURLs.isEmpty,
            "Picker selection uses explicit admission, not the derived-row route"
        )
    }

    func testFailedOpenDoesNotNavigateAndReportsUsefulError() async throws {
        let harness = try makeHarness { _, _ in throw IOSWorkspaceFailure.permissionDenied }
        harness.runtime.requestPicker(scope: .singleFile)
        let request = try XCTUnwrap(harness.runtime.pickerRequest)
        let task = try XCTUnwrap(harness.runtime.completePicker(request, urls: [URL(fileURLWithPath: "/tmp/post.md")]))
        await task.value
        XCTAssertTrue(harness.runtime.scene.navigationPath.isEmpty)
        XCTAssertEqual(harness.runtime.scene.presentedError?.title, "Couldn't Open")
        XCTAssertEqual(
            harness.runtime.scene.presentedError?.message,
            "Access is no longer available. Choose the file or folder again."
        )
        XCTAssertFalse(harness.runtime.isOpening)
    }

    func testDirectorySelectionDoesNotPushADocumentScreen() async throws {
        var scope: IOSWorkspaceScope?
        let harness = try makeHarness { _, selectedScope in scope = selectedScope }
        harness.runtime.requestPicker(scope: .directory)
        let request = try XCTUnwrap(harness.runtime.pickerRequest)
        let task = try XCTUnwrap(harness.runtime.completePicker(request, urls: [URL(fileURLWithPath: "/tmp/folder")]))
        await task.value
        XCTAssertEqual(scope, .directory)
        XCTAssertTrue(harness.runtime.scene.navigationPath.isEmpty)
    }

    func testHostedViewsRetainTheInjectedNativeProviders() throws {
        let harness = try makeHarness { _, _ in }
        XCTAssertTrue(harness.runtime.scene.editorHostView === harness.runtime.editor.textView)
        XCTAssertTrue(harness.runtime.scene.previewHostView === harness.runtime.preview.webView)
        harness.runtime.scene.showPane(.preview)
        harness.runtime.scene.showPane(.source)
        XCTAssertTrue(harness.runtime.scene.editorHostView === harness.runtime.editor.textView)
        XCTAssertTrue(harness.runtime.scene.previewHostView === harness.runtime.preview.webView)
    }

    func testReturningActiveCannotTransferFocusToAReplacementBinding() throws {
        let harness = try makeHarness { _, _ in }
        let identity = IOSDocumentIdentity(rawValue: UUID())
        let session = DocumentSession(text: "# Original", fileKind: .markdown)
        let firstBinding = UUID()
        harness.runtime.editor.attach(IOSSourceEditorDocumentBinding(
            bindingID: firstBinding, identity: identity, session: session,
            accessGeneration: 1, canWrite: true
        ))
        harness.runtime.editor.updateCommandFocus(for: identity, bindingID: firstBinding, isFocused: true)
        harness.runtime.scene.startObserving()
        harness.runtime.startObserving()
        harness.runtime.setSceneActive(false)
        let callsBeforeReplacement = harness.facade.setCommandFocusCalls.count
        harness.runtime.editor.attach(IOSSourceEditorDocumentBinding(
            bindingID: UUID(), identity: identity, session: session,
            accessGeneration: 1, canWrite: true
        ))
        harness.runtime.setSceneActive(true)
        XCTAssertEqual(harness.facade.setCommandFocusCalls.count, callsBeforeReplacement)
        XCTAssertFalse(harness.runtime.editor.captureSnapshot()?.isFocused ?? true)
        harness.runtime.scene.stopObserving()
    }

    func testRepeatedSheetFactoryDoesNotRestartFindOrLoseDrafts() throws {
        let harness = try makeHarness { _, _ in }
        let context = IOSShellSheetContext(
            facade: harness.facade, editor: harness.runtime.editor, presentation: .findReplace
        )
        let first = harness.runtime.scene.surfaces.makeAuthoringPanel?(.findReplace, context)
        harness.runtime.authoring.find.replacement = "Retain this draft"
        let generation = harness.runtime.authoring.find.queryGeneration
        let second = harness.runtime.scene.surfaces.makeAuthoringPanel?(.findReplace, context)
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertEqual(harness.runtime.authoring.find.queryGeneration, generation)
        XCTAssertEqual(harness.runtime.authoring.find.replacement, "Retain this draft")
        context.notifyDismissed()
        XCTAssertEqual(harness.runtime.authoring.find.replacement, "")
    }

    func testOSOpenRetiresPresentedPickerBeforeStartingTheNewOpen() async throws {
        var runtime: IOSProductionRuntime?
        var opened: [URL] = []
        let harness = try makeHarness { url, _ in
            XCTAssertNil(runtime?.pickerRequest)
            XCTAssertFalse(runtime?.showOpenChoices ?? true)
            XCTAssertEqual(runtime?.authoring.find.replacement, "")
            opened.append(url)
        }
        runtime = harness.runtime
        harness.runtime.requestPicker(scope: .singleFile)
        let old = try XCTUnwrap(harness.runtime.pickerRequest)
        harness.runtime.showOpenChoices = true
        harness.runtime.authoring.find.replacement = "Old draft"
        let delivered = URL(fileURLWithPath: "/tmp/os-delivery.md")
        await harness.runtime.openURL(delivered)
        XCTAssertNil(harness.runtime.completePicker(old, urls: [URL(fileURLWithPath: "/tmp/old-picker.md")]))
        XCTAssertEqual(opened, [delivered])
    }

    func testActiveMountedDetailClaimsTheNewBinding() async throws {
        let harness = try makeHarness { _, _ in }
        harness.runtime.startObserving()
        let identity = IOSDocumentIdentity(rawValue: UUID())
        let bindingID = UUID()
        harness.runtime.editor.attach(IOSSourceEditorDocumentBinding(
            bindingID: bindingID, identity: identity, session: DocumentSession(text: "New", fileKind: .markdown),
            accessGeneration: 1, canWrite: true
        ))
        try await waitUntil {
            harness.facade.setCommandFocusCalls.contains {
                $0.focused && $0.identity == identity && $0.bindingID == bindingID
            }
        }
    }

    func testFocusRejectedDuringAttachRetriesAtTheSettledAccessSnapshot() async throws {
        let harness = try makeHarness { _, _ in }
        harness.facade.commandFocusResult = false
        harness.runtime.startObserving()
        let identity = IOSDocumentIdentity(rawValue: UUID())
        let bindingID = UUID()
        harness.runtime.editor.attach(IOSSourceEditorDocumentBinding(
            bindingID: bindingID, identity: identity, session: DocumentSession(text: "New", fileKind: .markdown),
            accessGeneration: 1, canWrite: false
        ))
        try await waitUntil { !harness.facade.setCommandFocusCalls.isEmpty }
        let rejectedCalls = harness.facade.setCommandFocusCalls.count
        harness.facade.commandFocusResult = true
        harness.runtime.editor.updateAccess(for: identity, bindingID: bindingID, generation: 1, canWrite: true)
        try await waitUntil { harness.facade.setCommandFocusCalls.count > rejectedCalls }
        XCTAssertEqual(harness.facade.setCommandFocusCalls.last?.bindingID, bindingID)
        XCTAssertEqual(harness.facade.setCommandFocusCalls.last?.identity, identity)
    }

    func testShutdownPreservesARetainedWriterThenInvalidatesOnlyAfterClose() async throws {
        var canClose = false
        var closes = 0
        let harness = try makeHarness(shutdown: {
            closes += 1
            return canClose
        }) { _, _ in }
        harness.runtime.stopObserving()
        XCTAssertEqual(closes, 0, "Ordinary view disappearance is not scene disposal")
        let retained = await harness.runtime.shutdown()
        XCTAssertFalse(retained)
        XCTAssertNotNil(harness.runtime.preview.webView.navigationDelegate)
        canClose = true
        let closed = await harness.runtime.shutdown()
        XCTAssertTrue(closed)
        XCTAssertNil(harness.runtime.preview.webView.navigationDelegate)
        let closedAgain = await harness.runtime.shutdown()
        XCTAssertTrue(closedAgain)
        XCTAssertEqual(closes, 2)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for binding-specific command focus")
        throw IOSDocumentFailure.unavailable
    }

    private func makeHarness(
        shutdown: @escaping @MainActor () async -> Bool = { true },
        open: @escaping @MainActor (URL, IOSWorkspaceScope) async throws -> Void
    ) throws -> (runtime: IOSProductionRuntime, facade: FakeSceneFacade) {
        let editor = IOSSourceEditorController()
        let preview = PreviewController()
        let assets = IOSWorkspaceAccessFactory.makeProduction(recentKey: "SurfaceTests.\(UUID().uuidString)")
        let facade = FakeSceneFacade(capabilities: IOSSceneCapabilities(
            editor: editor, documents: nil, workspace: assets, preview: preview, assets: assets
        ))
        let runtime = try IOSProductionRuntime(
            controller: facade, editor: editor, preview: preview,
            currentGrant: { nil }, refreshWorkspace: {}, openPickedURL: open, shutdown: shutdown
        )
        addTeardownBlock { @MainActor in
            runtime.stopObserving()
            runtime.preview.invalidate()
        }
        return (runtime, facade)
    }
}
