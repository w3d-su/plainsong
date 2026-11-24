import AppKit
@testable import EditorKit
import XCTest

@MainActor
final class EditorFindMatchHighlightClearEditTests: XCTestCase {
    func testClearingAStorageWithoutDecorationDoesNotEditIt() {
        let storage = NSTextStorage(string: String(repeating: "no matches here\n", count: 200))
        var edits = 0
        let recordEdit: @MainActor () -> Void = { edits += 1 }
        let observer = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil
        ) { _ in
            MainActor.assumeIsolated { recordEdit() }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        EditorFindMatchHighlight.clear(in: storage)

        XCTAssertEqual(edits, 0, "nothing to clear must not invalidate the document's layout")
    }

    func testClearingStillRemovesAStrandedCoveredBackground() {
        let storage = NSTextStorage(string: "alpha needle beta")
        let stranded = NSRange(location: 6, length: 6)
        storage.addAttribute(
            EditorFindMatchHighlightMarker.coveredBackgroundAttribute,
            value: NSColor.systemYellow,
            range: stranded
        )

        EditorFindMatchHighlight.clear(in: storage)

        XCTAssertNil(storage.attribute(
            EditorFindMatchHighlightMarker.coveredBackgroundAttribute,
            at: stranded.location,
            effectiveRange: nil
        ))
    }
}
