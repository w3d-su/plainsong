import Foundation
import MarkdownCore
@testable import PlainsongIOS
import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSRecoveryProductionWorkflowTests: XCTestCase {
    func testReadOnlyRecoveryPresentationRetiresPendingCommandFocusAndAuthoringCapture() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RecoveryFocus-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("original.md")
        try Data("Keep native source".utf8).write(to: original)
        let runtime = try IOSProductionComposition
            .makeProduction(recoveryDirectory: root.appendingPathComponent("Drafts"))
        let controller = try XCTUnwrap(runtime.controller as? IOSDocumentSceneController)
        addTeardownBlock { @MainActor in
            runtime.stopObserving()
            runtime.scene.stopObserving()
            let closed = await runtime.shutdown()
            XCTAssertTrue(closed)
            if closed {
                try FileManager.default.removeItem(at: root)
            }
        }
        try await controller.openPickedURL(original, scope: .singleFile)
        runtime.scene.startObserving()
        runtime.startObserving() // Queues a binding-specific claim after Task.yield.
        let identity = try XCTUnwrap(controller.handle?.identity)
        let binding = try XCTUnwrap(controller.bindingID)
        XCTAssertTrue(controller.setCommandFocus(true, expected: identity, bindingID: binding))
        runtime.authoring.find.replacement = "Retire this owned draft"
        let source = try XCTUnwrap(controller.handle?.session.text)
        try XCTUnwrap(runtime.recovery).present()
        for _ in 0 ..< 3 {
            await Task.yield()
        }
        XCTAssertFalse(runtime.editor.captureSnapshot()?.isFocused ?? true)
        XCTAssertEqual(runtime.authoring.find.replacement, "")
        XCTAssertEqual(IOSShellActionRouter(scene: runtime.scene).perform(.bold), .notFocused)
        XCTAssertEqual(controller.handle?.session.text, source)
        XCTAssertTrue(runtime.scene.editorHostView === runtime.editor.textView)
    }

    func testRelaunchReadbackRestoresANewUIDocumentAndPreservesOriginalAndRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RecoveryWorkflow-\(UUID())")
        let recoveryDirectory = root.appendingPathComponent("Recovery", isDirectory: true)
        let destination = root.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("original.md")
        try Data("# Original stays unchanged\n".utf8).write(to: original)
        let record = recoveryRecord()
        let previousRun = IOSDocumentRecoveryStore(directory: recoveryDirectory)
        _ = try await previousRun.persist(record)
        let runtime = try IOSProductionComposition.makeProduction(recoveryDirectory: recoveryDirectory)
        let controller = try XCTUnwrap(runtime.controller as? IOSDocumentSceneController)
        let recovery = try XCTUnwrap(runtime.recovery)
        addTeardownBlock { @MainActor in
            runtime.stopObserving()
            runtime.scene.stopObserving()
            let closed = await runtime.shutdown()
            XCTAssertTrue(closed)
            if closed {
                try FileManager.default.removeItem(at: root)
            }
        }
        try await controller.openPickedURL(original, scope: .singleFile)
        let oldIdentity = controller.handle?.identity
        let access = try XCTUnwrap(controller.workspace as? IOSWorkspaceAccessService)
        let recentsBeforeRestore = access.recentItems()
        recovery.present()
        let presentationID = try XCTUnwrap(recovery.presentationID)
        XCTAssertTrue(recovery.didAppear(presentationID))
        await recovery.refresh()
        XCTAssertEqual(recovery.records.map(\.recordID), [record.recordID])
        await recovery.select(record.recordID)
        XCTAssertTrue(try ExactSourceText.matches(XCTUnwrap(recovery.detail?.source), record.source))
        recovery.requestRestore()
        let request = try XCTUnwrap(recovery.pickerRequest)
        let task = try XCTUnwrap(recovery.completePicker(request, urls: [destination]))
        await task.value
        XCTAssertNil(recovery.errorMessage)
        let restored = try XCTUnwrap(controller.handle)
        XCTAssertNotEqual(restored.identity, oldIdentity)
        XCTAssertEqual(restored.location.fileURL.deletingLastPathComponent(), destination)
        XCTAssertEqual(restored.location.fileURL.lastPathComponent, request.capture.filename)
        XCTAssertEqual(restored.session.text, record.source)
        XCTAssertEqual(runtime.editor.textView.text, record.source)
        XCTAssertFalse(restored.session.isDirty)
        XCTAssertEqual(controller.admission.active?.documentID, restored.identity)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "# Original stays unchanged\n")
        XCTAssertTrue(try ExactSourceText.matches(
            String(contentsOf: restored.location.fileURL, encoding: .utf8), record.source
        ))
        let nextRun = IOSDocumentRecoveryStore(directory: recoveryDirectory)
        let retained = try await nextRun.load(record.recordID)
        XCTAssertTrue(ExactSourceText.matches(retained.source, record.source))
        XCTAssertEqual(retained.baseline, record.baseline)
        XCTAssertEqual(access.recentItems(), recentsBeforeRestore, "restore-only folder must not become recent")
        let restoredTree = try XCTUnwrap(controller.snapshot.workspace)
        XCTAssertEqual(restoredTree.workspaceID, restored.location.workspaceID)
        XCTAssertEqual(restoredTree.accessGeneration, restored.location.accessGeneration)
        XCTAssertTrue(restoredTree.entries.contains {
            $0.location.relativePath.utf8.elementsEqual(request.capture.filename.utf8)
        }, "Files must show the newly restored file before any manual refresh")
        XCTAssertEqual(runtime.scene.navigationPath, [], "navigation waits for the actual recovery sheet dismissal")
        recovery.didDismiss(presentationID)
        XCTAssertEqual(runtime.scene.navigationPath, [.document])
    }
}
