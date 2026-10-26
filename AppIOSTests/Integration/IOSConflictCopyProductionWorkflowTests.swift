import EditorKitIOS
import Foundation
import MarkdownCore
@testable import PlainsongIOS
import UIKit
import WorkspaceCore
@testable import WorkspaceKitIOS
import XCTest

/// Real Files authority, UIDocument, native editor, recovery and create-new.
/// Conflict admission uses the existing testable method; provider UI is not exercised.
@MainActor
final class IOSConflictCopyProductionWorkflowTests: XCTestCase {
    func testRealProviderCopyPreservesOriginalConflictSourceUndoRecoveryAndAutosaveBarrier() async throws {
        let fixture = try IOSConflictCopyRealFixture()
        addTeardownBlock { @MainActor in await fixture.cleanup() }
        let handle = try await fixture.openConflict()
        let before = try IOSConflictCopyRealSnapshot(fixture: fixture, handle: handle)
        let list = await fixture.store.recoveryList()
        XCTAssertTrue(list.records.contains { $0.recordID == before.recovery.recordID && $0.source == before.source })
        let recentBeforeCopy = fixture.access.recentItems()
        let copy = IOSConflictCopyCoordinator(controller: fixture.controller)
        XCTAssertTrue(copy.requestSaveCopy())
        let draft = try XCTUnwrap(copy.draft)
        let request = try XCTUnwrap(copy.requestFolderPicker(draftID: draft.id, filename: "保存副本.md"))
        let task = try XCTUnwrap(copy.completePicker(request, urls: [fixture.destinationFolder]))
        let outcome = await task.value
        XCTAssertEqual(outcome, .saved(filename: request.filename))
        XCTAssertEqual(fixture.access.recentItems(), recentBeforeCopy)
        XCTAssertEqual(
            try String(contentsOf: fixture.destinationFolder.appendingPathComponent(request.filename), encoding: .utf8),
            before.source
        )
        try assertPreserved(fixture, before: before)
        try await assertAutosaveBarrier(fixture, before: before)
    }

    func testRealUnavailableDirtyWriterExportsItsSourceAfterOriginGrantRevocation() async throws {
        let fixture = try IOSConflictCopyRealFixture(autosaveDelayNanoseconds: 60_000_000_000)
        addTeardownBlock { @MainActor in await fixture.cleanup() }
        let handle = try await fixture.openConflict()
        let before = try IOSConflictCopyRealSnapshot(fixture: fixture, handle: handle)
        let entry = try XCTUnwrap(fixture.store.byIdentity[handle.identity])
        fixture.store.fenceUnavailable(entry, .access(.offline))
        _ = fixture.access.invalidate(before.grant.workspaceID)
        XCTAssertFalse(fixture.controller.grantIsCurrent)
        let generation = try XCTUnwrap(fixture.editor.captureSnapshot()).accessGeneration
        let recentBeforeCopy = fixture.access.recentItems()
        let copy = IOSConflictCopyCoordinator(controller: fixture.controller)
        XCTAssertTrue(copy.requestSaveCopy())
        let draft = try XCTUnwrap(copy.draft)
        let request = try XCTUnwrap(copy.requestFolderPicker(draftID: draft.id, filename: "Unavailable Copy.mdx"))
        let task = try XCTUnwrap(copy.completePicker(request, urls: [fixture.destinationFolder]))

        let outcome = await task.value

        XCTAssertEqual(outcome, .saved(filename: request.filename))
        XCTAssertEqual(fixture.access.recentItems(), recentBeforeCopy)
        XCTAssertEqual(
            try String(contentsOf: fixture.destinationFolder.appendingPathComponent(request.filename), encoding: .utf8),
            before.source
        )
        XCTAssertEqual(try String(contentsOf: fixture.original, encoding: .utf8), "# Original\n")
        XCTAssertTrue(fixture.controller.handle?.session === handle.session)
        XCTAssertEqual(handle.session.text, before.source)
        XCTAssertEqual(handle.session.version, before.version)
        XCTAssertTrue(handle.session.isDirty)
        XCTAssertTrue(fixture.editor.textView.undoManager === before.undo)
        XCTAssertEqual(before.undo.undoActionName, before.undoName)
        XCTAssertEqual(fixture.editor.captureSnapshot()?.accessGeneration, generation)
        XCTAssertFalse(fixture.editor.captureSnapshot()?.canWrite ?? true)
        XCTAssertEqual(try fixture.recoveryFiles(), before.recoveryBytes)
        guard case .unavailable = fixture.store.state(for: handle.identity) else {
            return XCTFail("The original must remain unavailable and admitted")
        }
    }

    func testProductionFactorySurfaceUsesTheCurrentWriterAndRetiresAuthoringFocus() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FactoryCopy-\(UUID())")
        let destination = root.appendingPathComponent("Copies", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("original.md")
        let source = "# Factory source\n"
        try Data(source.utf8).write(to: original)
        let runtime = try IOSProductionComposition
            .makeProduction(recoveryDirectory: root.appendingPathComponent("Recovery"))
        let controller = try XCTUnwrap(runtime.controller as? IOSDocumentSceneController)
        let store = try XCTUnwrap(controller.documents as? IOSUIDocumentStore)
        let copy = try XCTUnwrap(runtime.conflictCopy)
        addTeardownBlock { @MainActor in
            runtime.stopObserving()
            runtime.scene.stopObserving()
            // Fixture-only cleanup drains the conflicted writer without treating
            // Save a Copy as permission to close or replace the original.
            if let handle = controller.handle, let entry = store.byIdentity[handle.identity] {
                try await store.retireForReplacement(entry)
            }
            let closed = await runtime.shutdown()
            XCTAssertTrue(closed)
            if closed {
                try FileManager.default.removeItem(at: root)
            }
        }
        try await controller.openPickedURL(original, scope: .singleFile)
        runtime.scene.startObserving()
        runtime.startObserving()
        let handle = try XCTUnwrap(controller.handle)
        let binding = try XCTUnwrap(controller.bindingID)
        XCTAssertTrue(controller.setCommandFocus(true, expected: handle.identity, bindingID: binding))
        runtime.authoring.find.replacement = "Retire this captured authoring draft"
        let entry = try XCTUnwrap(store.byIdentity[handle.identity])
        await store.beginConflict(entry, reason: .externalConflict, allowRetry: true)
        try XCTUnwrap(runtime.scene.surfaces.resolveConflictCopy)()
        XCTAssertFalse(runtime.editor.captureSnapshot()?.isFocused ?? true)
        XCTAssertEqual(runtime.authoring.find.replacement, "")
        let draft = try XCTUnwrap(copy.draft)
        let request = try XCTUnwrap(copy.requestFolderPicker(draftID: draft.id, filename: "Factory Copy.md"))
        let task = try XCTUnwrap(copy.completePicker(request, urls: [destination]))
        let outcome = await task.value
        XCTAssertEqual(outcome, .saved(filename: request.filename))
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent(request.filename), encoding: .utf8),
            source
        )
        XCTAssertTrue(controller.handle?.session === handle.session)
        XCTAssertEqual(runtime.editor.textView.text, source)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), source)
        guard case .conflict = store.state(for: handle.identity) else {
            return XCTFail("The production copy hook must leave the original conflict admitted")
        }
    }

    func testManualReloadDuringNativeCompositionDefersAndPreservesMarkedTextAndUndo() async throws {
        let fixture = try IOSConflictCopyRealFixture(autosaveDelayNanoseconds: 60_000_000_000)
        addTeardownBlock { @MainActor in await fixture.cleanup() }
        try await fixture.controller.openPickedURL(fixture.original, scope: .singleFile)
        let handle = try XCTUnwrap(fixture.controller.handle)
        let binding = try XCTUnwrap(fixture.controller.bindingID)
        XCTAssertTrue(fixture.editor.textView.becomeFirstResponder())
        XCTAssertTrue(fixture.controller.setCommandFocus(true, expected: handle.identity, bindingID: binding))
        fixture.editor.textView.selectedRange = NSRange(location: handle.session.text.utf16.count, length: 0)
        fixture.editor.textView.insertText("!")
        fixture.editor.textView.setMarkedText("ㄓ", selectedRange: NSRange(location: 0, length: 1))
        XCTAssertNotNil(fixture.editor.textView.markedTextRange)
        let source = handle.session.text
        let nativeText = fixture.editor.textView.text
        let version = handle.session.version
        let selection = fixture.editor.textView.selectedRange
        let undo = try XCTUnwrap(fixture.editor.textView.undoManager)
        let undoName = undo.undoActionName
        XCTAssertTrue(undo.canUndo)

        try await fixture.controller.resolveExternal(.reload)

        XCTAssertNotNil(fixture.editor.textView.markedTextRange)
        XCTAssertEqual(fixture.editor.textView.text, nativeText)
        XCTAssertEqual(handle.session.text, source)
        XCTAssertEqual(handle.session.version, version)
        XCTAssertEqual(fixture.editor.textView.selectedRange, selection)
        XCTAssertTrue(fixture.editor.textView.undoManager === undo)
        XCTAssertTrue(undo.canUndo)
        XCTAssertEqual(undo.undoActionName, undoName)
        XCTAssertNotNil(fixture.store.byIdentity[handle.identity]?.pendingProposal)
        XCTAssertFalse(fixture.controller.transitioning)

        fixture.editor.textView.unmarkText()
        // A later unmarked snapshot retries the already admitted proposal; no
        // synthetic user edit, cancellation or second external read is needed.
        fixture.editor.updateCommandFocus(for: handle.identity, bindingID: binding, isFocused: false)
        XCTAssertNil(fixture.store.byIdentity[handle.identity]?.pendingProposal)
        XCTAssertEqual(handle.session.text, "# Original\n")
        XCTAssertEqual(fixture.editor.textView.text, "# Original\n")
        XCTAssertFalse(handle.session.isDirty)
        XCTAssertTrue(fixture.controller.handle?.session === handle.session)
    }

    private func assertPreserved(_ fixture: IOSConflictCopyRealFixture, before: IOSConflictCopyRealSnapshot) throws {
        XCTAssertEqual(try String(contentsOf: fixture.original, encoding: .utf8), "# Original\n")
        XCTAssertTrue(fixture.controller.handle?.session === before.handle.session)
        XCTAssertEqual(fixture.controller.currentGrant?.workspaceID, before.grant.workspaceID)
        XCTAssertEqual(fixture.controller.currentGrant?.accessGeneration, before.grant.accessGeneration)
        XCTAssertTrue(fixture.controller.grantIsCurrent)
        XCTAssertEqual(before.handle.session.text, before.source)
        XCTAssertEqual(before.handle.session.version, before.version)
        XCTAssertTrue(before.handle.session.isDirty)
        XCTAssertEqual(fixture.editor.textView.text, before.source)
        XCTAssertEqual(fixture.editor.textView.selectedRange, before.selection)
        XCTAssertTrue(fixture.editor.textView.undoManager === before.undo)
        XCTAssertTrue(before.undo.canUndo)
        XCTAssertEqual(before.undo.undoActionName, before.undoName)
        XCTAssertFalse(fixture.editor.captureSnapshot()?.canWrite ?? true)
        guard case let .conflict(_, afterRecovery) = fixture.store.state(for: before.handle.identity) else {
            return XCTFail("Copy must retain the original conflict")
        }
        XCTAssertEqual(afterRecovery?.recordID, before.recovery.recordID)
        XCTAssertEqual(try fixture.recoveryFiles(), before.recoveryBytes)
        let destinationIDs = fixture.access.records.keys.filter { $0 != before.grant.workspaceID }
        XCTAssertEqual(destinationIDs.count, 1)
        for id in destinationIDs {
            XCTAssertNil(fixture.access.currentGrant(for: id))
        }
        XCTAssertNotNil(fixture.access.currentGrant(for: before.grant.workspaceID))
    }

    private func assertAutosaveBarrier(
        _ fixture: IOSConflictCopyRealFixture, before: IOSConflictCopyRealSnapshot
    ) async throws {
        let entry = try XCTUnwrap(fixture.store.byIdentity[before.handle.identity])
        // Exercise the actual scheduler after success, preserving the conflict.
        fixture.store.scheduleAutosave(entry)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNil(entry.lastAcknowledgement)
        XCTAssertEqual(try String(contentsOf: fixture.original, encoding: .utf8), "# Original\n")
        XCTAssertEqual(before.handle.session.text, before.source)
        XCTAssertTrue(before.handle.session.isDirty)
        do {
            _ = try await fixture.controller.saveCurrentDocument()
            XCTFail("Original conflict must continue refusing overwrite")
        } catch { XCTAssertEqual(error as? IOSDocumentFailure, .conflict) }
    }
}

@MainActor
private struct IOSConflictCopyRealSnapshot {
    let handle: IOSDocumentHandle
    let grant: IOSWorkspaceGrant
    let source: String
    let version: Int
    let selection: NSRange
    let undo: UndoManager
    let undoName: String
    let recovery: IOSRecoveryReceipt
    let recoveryBytes: [String: Data]

    init(fixture: IOSConflictCopyRealFixture, handle: IOSDocumentHandle) throws {
        self.handle = handle
        grant = try XCTUnwrap(fixture.controller.currentGrant)
        source = handle.session.text
        version = handle.session.version
        selection = fixture.editor.textView.selectedRange
        undo = try XCTUnwrap(fixture.editor.textView.undoManager)
        XCTAssertTrue(undo.canUndo)
        undoName = undo.undoActionName
        guard case let .conflict(_, receipt) = fixture.store.state(for: handle.identity) else {
            throw IOSDocumentFailure.conflict
        }
        recovery = try XCTUnwrap(receipt)
        recoveryBytes = try fixture.recoveryFiles()
    }
}

@MainActor
private struct IOSConflictCopyRealFixture {
    let root: URL
    let original: URL
    let destinationFolder: URL
    let access = IOSWorkspaceAccessFactory.makeProduction()
    let store: IOSUIDocumentStore
    let editor = IOSSourceEditorController()
    let controller: IOSDocumentSceneController
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))

    init(autosaveDelayNanoseconds: UInt64 = 100_000_000) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        original = root.appendingPathComponent("original.md")
        destinationFolder = root.appendingPathComponent("copies", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        try Data("# Original\n".utf8).write(to: original)
        store = IOSUIDocumentStore(
            coordinatedAccess: access, recoveryDirectory: root.appendingPathComponent("recovery", isDirectory: true),
            timing: IOSDocumentTiming(
                autosaveDelayNanoseconds: autosaveDelayNanoseconds, backgroundFlushNanoseconds: 500_000_000
            )
        )
        let destinationAccess = access
        controller = IOSDocumentSceneController(
            documents: store, workspace: access, editor: editor, preview: IOSSceneControllerPreviewDouble(),
            assets: access, assetContext: { [weak access] in access?.previewContext(for: $0) },
            openDestinationFolder: { try await destinationAccess.openDestinationFolder(selectedURL: $0) }
        )
        let host = UIViewController()
        window.rootViewController = host
        editor.textView.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        host.view.addSubview(editor.textView)
        window.makeKeyAndVisible()
    }

    func openConflict() async throws -> IOSDocumentHandle {
        try await controller.openPickedURL(original, scope: .singleFile)
        let handle = try XCTUnwrap(controller.handle)
        XCTAssertTrue(editor.textView.becomeFirstResponder())
        XCTAssertTrue(try controller.setCommandFocus(
            true,
            expected: handle.identity,
            bindingID: XCTUnwrap(controller.bindingID)
        ))
        let before = try XCTUnwrap(editor.captureSnapshot())
        XCTAssertEqual(editor.apply(IOSAuthorizedEdit(
            bindingID: before.bindingID, baseRevision: before.revision,
            selectionGeneration: before.selectionGeneration, accessGeneration: before.accessGeneration,
            result: MarkdownEditResult(
                replacementRange: NSRange(location: 0, length: before.document.text.utf16.count),
                replacementString: "# 本機草稿\n繁中 Undo 👩🏽‍💻\n", newSelection: NSRange(location: 7, length: 0)
            ), undoActionName: "Conflict Copy Native Edit"
        )), .applied(IOSDocumentRevision(documentID: handle.identity, version: before.revision.version + 1)))
        let entry = try XCTUnwrap(store.byIdentity[handle.identity])
        await store.beginConflict(entry, reason: .externalConflict, allowRetry: true)
        return handle
    }

    func cleanup() async {
        editor.textView.resignFirstResponder()
        // Fixture-only retirement preserves recovery and drains the real writer.
        // The production copy operation never invokes this cleanup.
        if let handle = controller.handle, let entry = store.byIdentity[handle.identity] {
            do {
                try await store.retireForReplacement(entry)
            } catch {
                XCTFail("Fixture writer did not safely retire: \(error)")
            }
        }
        let closed = await controller.shutdown()
        XCTAssertTrue(closed)
        window.isHidden = true
        window.rootViewController = nil
        if closed {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func recoveryFiles() throws -> [String: Data] {
        let directory = root.appendingPathComponent("recovery", isDirectory: true)
        return try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(atPath: directory.path)
            .map { name in
                try (name, Data(contentsOf: directory.appendingPathComponent(name)))
            })
    }
}
