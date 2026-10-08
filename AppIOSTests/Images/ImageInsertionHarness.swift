import EditorKitIOS
import Foundation
import MarkdownCore
@testable import PlainsongIOS
import WorkspaceCore
import WorkspaceKitIOS
import XCTest

@MainActor
final class ImageInsertionHarness {
    let probe = InsertionProbe()
    let editor: ImageEditorFake
    let writer: PausableImageWriter
    let controller: IOSImageInsertionController
    let workspaceID = IOSWorkspaceIdentity(rawValue: UUID())
    let destination: IOSFileLocation
    let grant: IOSWorkspaceGrant
    let originalText: String
    let originalSelection: NSRange

    init(
        text: String = "Hello",
        selection: NSRange? = nil,
        scope: IOSWorkspaceScope = .directory,
        destinationGeneration: UInt64 = 8,
        editorAccessGeneration: UInt64 = 8,
        destinationURL: URL = URL(fileURLWithPath: "/Elsewhere/notes/post.md"),
        grantURL: URL = URL(fileURLWithPath: "/Authorized", isDirectory: true),
        transcoder: any IOSImageRasterTranscoding = RejectingTranscoder()
    ) {
        let resolvedSelection = selection ?? NSRange(location: (text as NSString).length, length: 0)
        originalText = text
        originalSelection = resolvedSelection
        editor = ImageEditorFake(
            probe: probe,
            text: text,
            selection: resolvedSelection,
            accessGeneration: editorAccessGeneration
        )
        writer = PausableImageWriter(probe: probe)
        controller = IOSImageInsertionController(
            writer: writer,
            normalizer: IOSImagePayloadNormalizer(transcoder: transcoder)
        )
        destination = IOSFileLocation(
            workspaceID: workspaceID,
            accessGeneration: destinationGeneration,
            relativePath: "notes/post.md",
            fileURL: destinationURL,
            resourceID: nil
        )
        grant = IOSWorkspaceGrant(
            workspaceID: workspaceID,
            rootURL: grantURL,
            accessGeneration: 8,
            scope: scope
        )
    }

    func capture() throws -> IOSImageInsertionContext {
        let context = controller.captureContext(using: editor, destination: destination, grant: grant)
        return try XCTUnwrap(context)
    }

    func insert(
        _ context: IOSImageInsertionContext,
        bytes: Data = ImageBytes.png,
        contentType: String = "image/png",
        filename: String = "from-photos.png"
    ) async -> IOSImageInsertionOutcome {
        await controller.insert(
            bytes: bytes,
            contentType: contentType,
            preferredFilename: filename,
            context: context,
            using: editor
        )
    }

    func session(onRequestDirectoryGrant: @escaping () -> Void = {}) -> IOSImageInsertionSession {
        IOSImageInsertionSession(
            controller: controller,
            editor: editor,
            destination: destination,
            grant: grant,
            onRequestDirectoryGrant: onRequestDirectoryGrant
        )
    }

    func assertSourceUntouched(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(editor.text, originalText, file: file, line: line)
        XCTAssertEqual(editor.selection, originalSelection, file: file, line: line)
        XCTAssertEqual(editor.undoInvocations, 0, file: file, line: line)
        XCTAssertEqual(editor.submitted.count, 0, file: file, line: line)
        XCTAssertEqual(writer.commitCount, 0, file: file, line: line)
    }
}

func assertRefused(
    _ outcome: IOSImageInsertionOutcome,
    _ reason: IOSEditRefusal,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case let .refused(actual) = outcome else {
        XCTFail("expected refused \(reason), got \(String(describing: outcome))", file: file, line: line)
        return
    }
    XCTAssertEqual(actual, reason, file: file, line: line)
}

func assertFailed(
    _ outcome: IOSImageInsertionOutcome,
    _ reason: IOSWorkspaceFailure,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case let .failed(actual) = outcome else {
        XCTFail("expected failed \(reason), got \(String(describing: outcome))", file: file, line: line)
        return
    }
    XCTAssertEqual(actual, reason, file: file, line: line)
}

func assertCancelled(
    _ outcome: IOSImageInsertionOutcome,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case .cancelled = outcome else {
        XCTFail("expected cancelled, got \(String(describing: outcome))", file: file, line: line)
        return
    }
}

func assertInserted(
    _ outcome: IOSImageInsertionOutcome,
    file: StaticString = #filePath,
    line: UInt = #line
) -> IOSDocumentRevision? {
    guard case let .inserted(revision, _) = outcome else {
        XCTFail("expected inserted, got \(String(describing: outcome))", file: file, line: line)
        return nil
    }
    return revision
}
