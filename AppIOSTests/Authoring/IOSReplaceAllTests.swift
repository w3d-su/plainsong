import Foundation
import MarkdownCore
@testable import PlainsongIOS
import XCTest

final class IOSReplaceAllTests: XCTestCase {
    @MainActor
    func testReplaceAllWritesEveryDifferingMatchInOneUndo() {
        let h = prepared("alpha beta alpha", pattern: "alpha", replacement: "X")
        h.controller.perform(.replaceAll, using: h.editor)
        XCTAssertEqual(h.editor.applyCount, 1)
        XCTAssertEqual(h.editor.undoCount, 1)
        XCTAssertEqual(h.editor.submitted.last?.undoActionName, "Replace All")
        XCTAssertTrue(ExactSourceText.matches(h.editor.text, "X beta X"))
        XCTAssertEqual(h.controller.find.message, "Replaced 2 matches.")
        XCTAssertNil(h.controller.find.session?.currentOrdinal)
        XCTAssertEqual(h.controller.find.session?.total, 0)
    }

    @MainActor
    func testReplaceAllPreservesTextBetweenMatches() {
        let h = prepared("one\nalpha\ntwo\nalpha\n", pattern: "alpha", replacement: "BETA")
        h.controller.perform(.replaceAll, using: h.editor)
        XCTAssertTrue(ExactSourceText.matches(h.editor.text, "one\nBETA\ntwo\nBETA\n"))
        XCTAssertEqual(h.editor.submitted.last?.result.replacementRange, NSRange(location: 4, length: 15))
    }

    @MainActor
    func testIdenticalReplacementDoesNotEdit() {
        let h = prepared("alpha beta alpha", pattern: "alpha", replacement: "alpha")
        h.controller.perform(.replaceAll, using: h.editor)
        XCTAssertEqual(h.editor.applyCount, 0)
        XCTAssertEqual(h.editor.undoCount, 0)
        XCTAssertTrue(ExactSourceText.matches(h.editor.text, "alpha beta alpha"))
        XCTAssertEqual(h.controller.find.message, "Every match already has that text.")
    }

    @MainActor
    func testChangedSourceRefreshesInsteadOfWriting() {
        let h = prepared("alpha beta", pattern: "alpha", replacement: "X")
        h.editor.text = "gamma beta"
        h.editor.version += 1
        h.controller.perform(.replaceAll, using: h.editor)
        XCTAssertEqual(h.editor.applyCount, 0)
        XCTAssertTrue(ExactSourceText.matches(h.editor.text, "gamma beta"))
        XCTAssertEqual(h.controller.find.status, .searching)
        XCTAssertEqual(h.controller.statusMessage, "The document changed. Find results are being refreshed.")
    }

    @MainActor
    func testMarkedTextRefusesReplaceAll() {
        let h = prepared("alpha beta", pattern: "alpha", replacement: "X")
        h.editor.hasMarkedText = true
        h.controller.perform(.replaceAll, using: h.editor)
        XCTAssertEqual(h.editor.applyCount, 0)
        XCTAssertEqual(h.controller.statusMessage, IOSAuthoringCatalog.compositionRefusal)
    }

    @MainActor
    func testNewlineReplacementIsRefused() {
        let h = prepared("alpha beta", pattern: "alpha", replacement: "a\nb")
        h.controller.perform(.replaceAll, using: h.editor)
        XCTAssertEqual(h.editor.applyCount, 0)
        XCTAssertEqual(h.controller.statusMessage, "Replacement can't contain a line break.")
    }

    @MainActor
    private func prepared(_ text: String, pattern: String, replacement: String) -> AuthoringHarness {
        let h = AuthoringHarness(text: text, selection: NSRange(location: 0, length: 0))
        h.controller.setFindQuery(pattern, using: h.editor)
        h.scheduler.finishLatest()
        h.controller.setReplacement(replacement)
        XCTAssertEqual(h.controller.find.status, .matches)
        return h
    }
}
