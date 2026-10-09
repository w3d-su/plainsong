import Foundation
import MarkdownCore
@testable import PlainsongIOS
import XCTest

final class IOSAcceptedFindProtectionTests: XCTestCase {
    @MainActor
    func testAcceptedFindCannotReplaceDifferentLatestSource() {
        let h = prepared()
        h.editor.text = "gamma beta"
        h.editor.version += 1
        h.editor.selectionGeneration += 1
        h.controller.perform(.singleReplace, using: h.editor)
        XCTAssertEqual(h.editor.text, "gamma beta")
        XCTAssertEqual(h.editor.applyCount, 0)
        XCTAssertEqual(h.editor.undoCount, 0)
        XCTAssertEqual(h.controller.find.status, .searching)
        h.scheduler.finishLatest()
        XCTAssertEqual(h.controller.find.status, .noResults)
    }

    @MainActor
    func testAcceptedFindCannotReplaceAnotherDocument() {
        let h = prepared()
        h.editor.identity = IOSDocumentIdentity(rawValue: UUID())
        h.editor.bindingID = UUID()
        h.editor.text = "gamma beta"
        h.controller.perform(.singleReplace, using: h.editor)
        XCTAssertEqual(h.editor.text, "gamma beta")
        XCTAssertEqual(h.editor.applyCount, 0)
        XCTAssertEqual(h.editor.undoCount, 0)
    }

    @MainActor
    func testSameDocumentReboundInstallationCannotUseAcceptedFind() {
        let h = prepared()
        h.editor.bindingID = UUID()
        h.controller.perform(.singleReplace, using: h.editor)
        XCTAssertEqual(h.editor.text, "alpha beta")
        XCTAssertEqual(h.editor.applyCount, 0)
        XCTAssertEqual(h.controller.find.status, .searching)
    }

    @MainActor
    func testNextAfterSourceChangeRecomputesBeforeReveal() {
        assertNavigationRecomputes(.nextMatch)
    }

    @MainActor
    func testPreviousAfterSourceChangeRecomputesBeforeReveal() {
        assertNavigationRecomputes(.previousMatch)
    }

    @MainActor
    private func prepared() -> AuthoringHarness {
        let h = AuthoringHarness(text: "alpha beta", selection: NSRange(location: 0, length: 5))
        h.controller.setFindQuery("alpha", using: h.editor)
        h.scheduler.finishLatest()
        h.controller.setReplacement("X")
        XCTAssertEqual(h.controller.find.session?.currentMatch?.range, NSRange(location: 0, length: 5))
        return h
    }

    @MainActor
    private func assertNavigationRecomputes(_ action: IOSAuthoringActionID) {
        let h = prepared()
        h.editor.text = "xx alpha"
        h.editor.version += 1
        h.controller.perform(action, using: h.editor)
        XCTAssertEqual(h.editor.revealCalls.count, 0)
        XCTAssertEqual(h.editor.applyCount, 0)
        h.scheduler.finishLatest()
        XCTAssertEqual(h.editor.revealCalls.last?.range, NSRange(location: 3, length: 5))
        XCTAssertEqual(h.editor.revealCalls.last?.revision, h.editor.revision)
    }
}
