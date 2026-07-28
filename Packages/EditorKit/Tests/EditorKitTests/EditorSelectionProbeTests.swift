import AppKit
@testable import EditorKit
import XCTest

/// The applied-selection probe must carry the provenance of the source the range belongs to.
/// A bare range is unsafe: during a document switch or a same-URL Reload the native view
/// still holds the previous content.
@MainActor
final class EditorSelectionProbeTests: XCTestCase {
    override func tearDown() {
        EditorFindControllerTestSupport.tearDownWindows()
        super.tearDown()
    }

    private let documentA = EditorDocumentIdentity(rawValue: "document-a")

    func testAppliedSelectionReportsInstalledDocumentIdentityAndRevision() throws {
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
        fixture.textView.textSelection = target
        let applied = try XCTUnwrap(
            EditorSelectionProbe.appliedEditorSelection(in: fixture.window)
        )
        XCTAssertEqual(applied.range, target)
        XCTAssertEqual(
            applied.documentIdentity,
            documentA,
            "Callers cannot validate a range without knowing which document it indexes"
        )
        XCTAssertTrue(applied.isDocumentInstalled)
    }

    func testAppliedSelectionIsReadableWhileTheEditorIsNotFirstResponder() throws {
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
        fixture.textView.textSelection = target
        let field = NSTextField(string: "find-query")
        field.frame = NSRect(x: 0, y: 0, width: 120, height: 24)
        fixture.window.contentView?.addSubview(field)
        guard fixture.window.makeFirstResponder(field) else {
            throw XCTSkip("makeFirstResponder(field) unavailable in this runner")
        }
        // The focused-editor probe correctly reports nothing; the applied probe still answers,
        // which is what ⌘E needs while the find field owns focus.
        XCTAssertNil(EditorSelectionProbe.editorSelection(in: fixture.window))
        let applied = try XCTUnwrap(
            EditorSelectionProbe.appliedEditorSelection(in: fixture.window)
        )
        XCTAssertEqual(applied.range, target)
        XCTAssertEqual(applied.documentIdentity, documentA)
    }

    func testEditorFocusIsScopedToTheWindowAsked() throws {
        // `keyWindowHasEditorFocus()` answers about `NSApp.keyWindow`, which is the wrong
        // question for a caller asking about a specific window — and gave the wrong answer
        // when a different window held editor focus.
        let source = "alpha needle omega"
        let model = EditorFindControllerTestSupport.FindNavModel(
            text: source,
            selection: NSRange(location: 0, length: 0)
        )
        let withEditor = try EditorFindControllerTestSupport.makeWindowedFixture(
            model: model,
            source: source,
            documentIdentity: documentA
        )
        XCTAssertTrue(
            withEditor.window.firstResponder === withEditor.textView,
            "precondition: this window's editor holds first responder"
        )

        let other = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        other.isReleasedWhenClosed = false
        defer { other.orderOut(nil) }
        let decoy = NSTextField(string: "not-an-editor")
        decoy.frame = NSRect(x: 0, y: 0, width: 120, height: 24)
        other.contentView?.addSubview(decoy)
        guard other.makeFirstResponder(decoy) else {
            throw XCTSkip("makeFirstResponder(decoy) unavailable in this runner")
        }

        XCTAssertTrue(EditorSelectionProbe.hasEditorFocus(in: withEditor.window))
        XCTAssertFalse(
            EditorSelectionProbe.hasEditorFocus(in: other),
            "A window without editor focus must answer false even while another window has it"
        )
        XCTAssertNotNil(EditorSelectionProbe.editorTextView(focusedIn: withEditor.window))
        XCTAssertNil(EditorSelectionProbe.editorTextView(focusedIn: other))
    }
}
