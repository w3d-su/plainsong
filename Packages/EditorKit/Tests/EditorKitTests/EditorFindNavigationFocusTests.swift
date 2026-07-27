import AppKit
@testable import EditorKit
import XCTest

/// In-document find navigates the editor selection without taking first responder, so a
/// match landing mid-query cannot interrupt typing in the find field.
@MainActor
final class EditorFindNavigationFocusTests: XCTestCase {
    private let documentA = EditorDocumentIdentity(rawValue: "document-a")

    func testFindNavigationSelectsAndScrollsWithoutStealingFirstResponder() throws {
        let source = (0 ... 300)
            .map { $0 == 280 ? "line \($0) exact 🧪 needle" : "line \($0) filler" }
            .joined(separator: "\n")
        let target = (source as NSString).range(of: "exact 🧪 needle")
        let model = EditorFindControllerTestSupport.FindNavModel(
            text: source,
            selection: NSRange(location: 0, length: 0)
        )
        let fixture = try EditorFindControllerTestSupport.makeWindowedFixture(
            model: model,
            source: source,
            documentIdentity: documentA,
            height: 100
        )
        fixture.textView.textSelection = NSRange(location: 0, length: 0)
        // The fixture leaves the editor as first responder, so a stolen-focus regression is
        // observable; hand focus to a decoy find field for the navigation under test.
        XCTAssertTrue(fixture.window.firstResponder === fixture.textView)
        let decoy = NSTextField(string: "find-query")
        decoy.frame = NSRect(x: 0, y: 0, width: 120, height: 24)
        fixture.window.contentView?.addSubview(decoy)
        guard fixture.window.makeFirstResponder(decoy) else {
            throw XCTSkip("makeFirstResponder(decoy) unavailable in this runner")
        }

        let request = EditorNavigationRequest(
            id: 11,
            documentIdentity: documentA,
            selection: target,
            shouldFocusEditor: false
        )
        fixture.coordinator.observeNavigationCommand(.navigate(request))
        fixture.coordinator.applyPendingNavigationIfPossible(in: fixture.textView)

        XCTAssertEqual(fixture.textView.selectedRange(), target)
        XCTAssertFalse(
            fixture.window.firstResponder === fixture.textView,
            "Find-style navigation must not claim editor first responder"
        )
    }

    func testDefaultNavigationStillFocusesTheEditor() throws {
        let source = "alpha needle omega"
        let target = (source as NSString).range(of: "needle")
        let model = EditorFindControllerTestSupport.FindNavModel(
            text: source,
            selection: NSRange(location: 0, length: 0)
        )
        let fixture = try EditorFindControllerTestSupport.makeWindowedFixture(
            model: model,
            source: source,
            documentIdentity: documentA
        )
        let decoy = NSTextField(string: "decoy")
        decoy.frame = NSRect(x: 0, y: 0, width: 120, height: 24)
        fixture.window.contentView?.addSubview(decoy)
        guard fixture.window.makeFirstResponder(decoy) else {
            throw XCTSkip("makeFirstResponder(decoy) unavailable in this runner")
        }

        // Workspace-search style navigation keeps the default `shouldFocusEditor: true`.
        let request = EditorNavigationRequest(
            id: 12,
            documentIdentity: documentA,
            selection: target
        )
        fixture.coordinator.observeNavigationCommand(.navigate(request))
        fixture.coordinator.applyPendingNavigationIfPossible(in: fixture.textView)

        XCTAssertEqual(fixture.textView.selectedRange(), target)
        XCTAssertTrue(
            fixture.window.firstResponder === fixture.textView,
            "Default navigation must still focus the editor"
        )
    }
}
