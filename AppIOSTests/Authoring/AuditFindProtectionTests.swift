import Foundation
import MarkdownCore
@testable import PlainsongIOS
import XCTest

/// Audit-only regression probes. Production sources are unmodified lane 08.
final class AuditFindProtectionTests: XCTestCase {
    @MainActor
    func testAcceptedFindCannotReplaceDifferentLatestSource() {
        let h = AuthoringHarness(text: "alpha beta", selection: NSRange(location: 0, length: 5))
        h.controller.setFindQuery("alpha", using: h.editor)
        h.scheduler.finishLatest()
        XCTAssertEqual(h.controller.find.session?.currentMatch?.range, NSRange(location: 0, length: 5))
        h.controller.setReplacement("X")
        h.editor.text = "gamma beta"
        h.editor.version += 1
        h.editor.selectionGeneration += 1
        h.controller.perform(.singleReplace, using: h.editor)
        XCTAssertEqual(h.editor.text, "gamma beta")
        XCTAssertEqual(h.editor.applyCount, 0)
        XCTAssertEqual(h.editor.undoCount, 0)
    }

    @MainActor
    func testAcceptedFindCannotReplaceAnotherDocument() {
        let h = AuthoringHarness(text: "alpha beta", selection: NSRange(location: 0, length: 5))
        h.controller.setFindQuery("alpha", using: h.editor)
        h.scheduler.finishLatest()
        h.controller.setReplacement("X")
        h.editor.identity = IOSDocumentIdentity(rawValue: UUID())
        h.editor.bindingID = UUID()
        h.editor.text = "gamma beta"
        h.controller.perform(.singleReplace, using: h.editor)
        XCTAssertEqual(h.editor.text, "gamma beta")
        XCTAssertEqual(h.editor.applyCount, 0)
    }
}
