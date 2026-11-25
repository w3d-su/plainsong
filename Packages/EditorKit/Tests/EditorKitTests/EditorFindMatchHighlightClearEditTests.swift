import AppKit
@testable import EditorKit
import XCTest

@MainActor
final class EditorFindMatchHighlightClearEditTests: XCTestCase {
    func testClearingAStorageWithoutDecorationDoesNotEditIt() {
        let storage = NSTextStorage(string: String(repeating: "no matches here\n", count: 200))
        let edits = EditCounter(storage)

        EditorFindMatchHighlight.clear(in: storage)

        XCTAssertEqual(edits.count, 0, "nothing to clear must not invalidate the document's layout")
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

    private final class EditCounter {
        private(set) var count = 0
        private var token: NSObjectProtocol?

        init(_ storage: NSTextStorage) {
            token = NotificationCenter.default.addObserver(
                forName: NSTextStorage.didProcessEditingNotification,
                object: storage,
                queue: nil
            ) { [weak self] _ in
                self?.count += 1
            }
        }

        deinit {
            if let token {
                NotificationCenter.default.removeObserver(token)
            }
        }
    }
}
