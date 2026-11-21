@testable import EditorKitIOS
import MarkdownCore
import UIKit
import XCTest

/// Audit-only regression probe. Production sources are unmodified lane 04.
final class AuditHistoryProtectionTests: XCTestCase {
    @MainActor
    func testUndoAfterRevocationDoesNotMutate() throws {
        let h = IOSEditorHarness(text: "hello")
        let result = MarkdownEditResult(
            replacementRange: NSRange(location: 0, length: 5),
            replacementString: "changed",
            newSelection: NSRange(location: 7, length: 0)
        )
        guard case .applied = try h.controller.apply(h.edit(result, name: "Change")) else {
            return XCTFail("setup edit refused")
        }
        XCTAssertTrue(h.textView.undoManager?.canUndo ?? false)
        h.controller.updateAccess(for: h.identity, bindingID: h.bindingID, generation: 2, canWrite: false)
        let text = h.session.text
        let version = h.session.version
        let selection = h.textView.selectedRange
        h.controller.undo()
        XCTAssertEqual(h.textView.textStorage.string, text)
        XCTAssertTrue(h.textView.undoManager?.canUndo ?? false)
        h.textView.undoManager?.undo()
        XCTAssertEqual(h.textView.textStorage.string, text)
        XCTAssertEqual(h.session.text, text)
        XCTAssertEqual(h.session.version, version)
        XCTAssertEqual(h.textView.selectedRange, selection)
    }

    @MainActor
    func testBlockedNativeUndoRetiresOlderRangesBeforeAccessReturns() throws {
        let h = IOSEditorHarness(text: "original")
        let manager = try XCTUnwrap(h.textView.undoManager)
        manager.groupsByEvent = false
        for prefix in ["first ", "second "] {
            let result = MarkdownEditResult(
                replacementRange: NSRange(location: 0, length: 0),
                replacementString: prefix,
                newSelection: NSRange(location: prefix.utf16.count, length: 0)
            )
            guard case .applied = try h.controller.apply(h.edit(result, name: "Insert")) else {
                return XCTFail("setup edit refused")
            }
        }
        XCTAssertTrue(manager.canUndo)
        h.controller.updateAccess(for: h.identity, bindingID: h.bindingID, generation: 2, canWrite: false)
        manager.undo()
        XCTAssertFalse(manager.canUndo)
        XCTAssertFalse(manager.canRedo)
        h.controller.updateAccess(for: h.identity, bindingID: h.bindingID, generation: 3, canWrite: true)
        h.controller.undo()
        XCTAssertEqual(h.session.text, "second first original")
    }
}
