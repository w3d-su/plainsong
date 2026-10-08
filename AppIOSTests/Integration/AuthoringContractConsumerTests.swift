import EditorKitIOS
import Foundation
import MarkdownCore
@testable import PlainsongIOS
import XCTest

final class AuthoringContractConsumerTests: XCTestCase {
    @MainActor
    func testIndependentAuthoringConsumerUsesCapturedRevisionAndGenerations() throws {
        let editor = CapturingEditorDouble()
        let snapshot = try XCTUnwrap(editor.captureSnapshot())
        let consumer = AuthoringConsumer(editor: editor)
        XCTAssertEqual(try consumer.bold(), .refused(.readOnly))
        let submitted = try XCTUnwrap(editor.submitted)
        XCTAssertEqual(submitted.bindingID, snapshot.bindingID)
        XCTAssertEqual(submitted.baseRevision, snapshot.revision)
        XCTAssertEqual(submitted.selectionGeneration, snapshot.selectionGeneration)
        XCTAssertEqual(submitted.accessGeneration, snapshot.accessGeneration)
        XCTAssertEqual(editor.session.snapshot, snapshot.document)
        XCTAssertEqual(editor.captureSnapshot()?.selection, snapshot.selection)
    }

    func testScaffoldBundlesSharedPreviewResourcesWithoutCreatingADocument() throws {
        for (name, suffix) in [("index", "html"), ("bundle", "js"), ("bundle", "css")] {
            let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: suffix, subdirectory: "preview"))
            XCTAssertGreaterThan(try Data(contentsOf: url).count, 0)
        }
    }

    @MainActor
    func testC0CompositionCannotSupplyAnyProductionProvider() {
        let composition = IOSProductionComposition.c0
        XCTAssertNil(composition.capabilities.editor)
        XCTAssertNil(composition.capabilities.documents)
        XCTAssertNil(composition.capabilities.workspace)
        XCTAssertNil(composition.capabilities.preview)
        XCTAssertNil(composition.capabilities.assets)
        XCTAssertFalse(composition.unavailableMessage.isEmpty)
    }
}

@MainActor
private struct AuthoringConsumer {
    let editor: any IOSSourceEditorControlling

    func bold() throws -> IOSEditOutcome {
        let snapshot = try XCTUnwrap(editor.captureSnapshot())
        let result = try XCTUnwrap(MarkdownEditing.apply(
            .format(.bold), to: snapshot.document.text, selection: snapshot.selection
        ))
        return editor.apply(IOSAuthorizedEdit(
            bindingID: snapshot.bindingID, baseRevision: snapshot.revision,
            selectionGeneration: snapshot.selectionGeneration,
            accessGeneration: snapshot.accessGeneration, result: result, undoActionName: "Bold"
        ))
    }
}

@MainActor
private final class CapturingEditorDouble: IOSSourceEditorBinding {
    let bindingID = UUID()
    let identity = IOSDocumentIdentity(rawValue: UUID())
    let session = DocumentSession(text: "繁中 text")
    var submitted: IOSAuthorizedEdit?

    func captureSnapshot() -> IOSSourceEditorSnapshot? {
        IOSSourceEditorSnapshot(
            bindingID: bindingID, revision: IOSDocumentRevision(documentID: identity, version: session.version),
            document: session.snapshot,
            selection: NSRange(location: 0, length: 2), visibleRange: NSRange(location: 0, length: 7),
            selectionGeneration: 5, accessGeneration: 9, hasMarkedText: false, canWrite: false, isFocused: true
        )
    }

    func apply(_ edit: IOSAuthorizedEdit) -> IOSEditOutcome {
        submitted = edit
        return .refused(.readOnly)
    }

    func reveal(_: NSRange, expected _: IOSDocumentRevision) -> Bool {
        false
    }

    func undo() {}
    func redo() {}
    func attach(_: IOSSourceEditorDocumentBinding) {}
    func detach(expected _: IOSDocumentIdentity, bindingID _: UUID) {}
    func updateAccess(for _: IOSDocumentIdentity, bindingID _: UUID, generation _: UInt64, canWrite _: Bool) {}
    func updateCommandFocus(for _: IOSDocumentIdentity, bindingID _: UUID, isFocused _: Bool) {}
    func installExternalReload(_: IOSDocumentReloadProposal) -> IOSDocumentReloadOutcome {
        .deferred
    }

    func observe(_: @escaping @MainActor (IOSSourceEditorEvent) -> Void) -> any IOSObservation {
        ObservationDouble()
    }
}

@MainActor
private final class ObservationDouble: IOSObservation {
    func cancel() {}
}
