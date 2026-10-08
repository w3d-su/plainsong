import EditorKitIOS
import Foundation
import MarkdownCore
import XCTest

final class EditorContractConsumerTests: XCTestCase {
    @MainActor
    func testConsumerCanObserveUnavailableEditorWithoutCreatingSource() {
        let editor: any IOSSourceEditorControlling = UnavailableEditorDouble()
        XCTAssertNil(editor.captureSnapshot())
        XCTAssertFalse(editor.reveal(NSRange(location: 0, length: 0), expected: IOSDocumentRevision(
            documentID: IOSDocumentIdentity(rawValue: UUID()), version: 0
        )))
    }
}

@MainActor
private final class UnavailableEditorDouble: IOSSourceEditorControlling {
    func captureSnapshot() -> IOSSourceEditorSnapshot? {
        nil
    }

    func apply(_: IOSAuthorizedEdit) -> IOSEditOutcome {
        .refused(.unavailable)
    }

    func reveal(_: NSRange, expected _: IOSDocumentRevision) -> Bool {
        false
    }

    func undo() {}
    func redo() {}
}
