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
        let field = NSTextField(string: "find-query")
        field.frame = NSRect(x: 0, y: 0, width: 120, height: 24)
        fixture.window.contentView?.addSubview(field)
        guard fixture.window.makeFirstResponder(field) else {
            throw XCTSkip("makeFirstResponder(field) unavailable in this runner")
        }
        // Production shape: a focused NSTextField is *not* the first responder — its field
        // editor is. Restoring that transient object instead of the control is exactly the
        // regression this test exists for.
        let fieldEditor = try XCTUnwrap(field.currentEditor())
        XCTAssertTrue(fixture.window.firstResponder === fieldEditor)

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
        XCTAssertNotNil(
            field.currentEditor(),
            "The find field must still own a field editor, so it can accept typing"
        )
    }

    /// STTextView does not claim first responder on every layout, so the end-to-end
    /// navigation test cannot force the capture/restore path. Drive it directly.
    func testCapturedFocusOwnerIsTheControlAndRestoreLeavesTheFindFieldTypable() throws {
        let source = "alpha needle omega"
        let model = EditorFindControllerTestSupport.FindNavModel(
            text: source,
            selection: NSRange(location: 0, length: 0)
        )
        let fixture = try EditorFindControllerTestSupport.makeWindowedFixture(
            model: model,
            source: source,
            documentIdentity: documentA
        )
        let field = NSTextField(string: "find-query")
        field.frame = NSRect(x: 0, y: 0, width: 120, height: 24)
        fixture.window.contentView?.addSubview(field)
        guard fixture.window.makeFirstResponder(field) else {
            throw XCTSkip("makeFirstResponder(field) unavailable in this runner")
        }
        let fieldEditor = try XCTUnwrap(field.currentEditor())
        XCTAssertTrue(
            fixture.window.firstResponder === fieldEditor,
            "Precondition: a focused NSTextField is represented by its field editor"
        )

        // What navigation captures before touching the selection.
        let captured = MarkdownTextViewCoordinator.focusOwner(of: fixture.window.firstResponder)
        XCTAssertTrue(
            captured === field,
            "Must capture the owning control; the field editor is unmounted when it resigns"
        )

        // Now reproduce the steal: STTextView takes first responder while selection is applied.
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.textView))
        XCTAssertNil(field.currentEditor(), "The field editor is detached once the field resigns")

        fixture.coordinator.restoreFocusOwner(
            captured,
            in: fixture.window,
            editor: fixture.textView
        )

        let restoredEditor = try XCTUnwrap(
            field.currentEditor(),
            "Restore must re-install the field's editor, not aim at the detached one"
        )
        XCTAssertTrue(
            fixture.window.firstResponder === restoredEditor
                || fixture.window.firstResponder === field,
            "Focus must return to the find field, got \(String(describing: fixture.window.firstResponder))"
        )

        // Prove it end to end: typed characters still reach the find field.
        let restoredTextView = try XCTUnwrap(restoredEditor as? NSTextView)
        restoredTextView.insertText("z", replacementRange: restoredTextView.selectedRange())
        XCTAssertTrue(
            field.stringValue.contains("z"),
            "Typing after find navigation must still land in the find field"
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
