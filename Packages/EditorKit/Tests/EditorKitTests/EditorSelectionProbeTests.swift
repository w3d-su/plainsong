import AppKit
@testable import EditorKit
import XCTest

/// The applied-selection probe must carry the provenance of the source the range belongs to.
/// A bare range is unsafe: during a document switch or a same-URL Reload the native view
/// still holds the previous content.
@MainActor
final class EditorSelectionProbeTests: XCTestCase {
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
}
