@testable import EditorKitIOS
import MarkdownCore
import UIKit
import XCTest

final class IOSAuthorizedEditTests: XCTestCase {
    @MainActor
    func testFormatAndSingleReplaceAreOneNativeUndo() throws {
        let harness = IOSEditorHarness(text: "hello")
        harness.textView.selectedRange = NSRange(location: 0, length: 5)
        let format = try XCTUnwrap(MarkdownEditing.apply(
            .format(.bold),
            to: "hello",
            selection: harness.textView.selectedRange
        ))
        let formatEdit = try harness.edit(format, name: "Bold")
        XCTAssertEqual(harness.controller.apply(formatEdit), .applied(IOSDocumentRevision(
            documentID: harness.identity,
            version: harness.session.version
        )))
        XCTAssertEqual(harness.textView.textStorage.string, "**hello**")
        XCTAssertEqual(harness.textView.undoManager?.undoActionName, "Bold")
        harness.controller.undo()
        XCTAssertEqual(harness.textView.textStorage.string, "hello")
        XCTAssertEqual(harness.session.text, "hello")
        harness.controller.redo()
        XCTAssertEqual(harness.textView.textStorage.string, "**hello**")

        let replace = MarkdownEditResult(
            replacementRange: NSRange(location: 0, length: iosUTF16("**hello**")),
            replacementString: "replaced",
            newSelection: NSRange(location: iosUTF16("replaced"), length: 0)
        )
        XCTAssertEqual(try harness.controller.apply(harness.edit(replace, name: "Replace")), .applied(
            IOSDocumentRevision(documentID: harness.identity, version: harness.session.version)
        ))
        XCTAssertEqual(harness.textView.textStorage.string, "replaced")
        harness.controller.undo()
        XCTAssertEqual(harness.textView.textStorage.string, "**hello**")
        harness.controller.redo()
        XCTAssertEqual(harness.textView.textStorage.string, "replaced")
    }

    @MainActor
    func testImageInsertionIsOneUndoAndRefusalsLeaveSourceSelectionAndUndoUntouched() throws {
        let harness = IOSEditorHarness(text: "body")
        let image = MarkdownEditResult(
            replacementRange: NSRange(location: 0, length: 0),
            replacementString: "![](assets/a.png)\n",
            newSelection: NSRange(location: iosUTF16("![](assets/a.png)\n"), length: 0)
        )
        XCTAssertEqual(try harness.controller.apply(harness.edit(image, name: "Insert Image")), .applied(
            IOSDocumentRevision(documentID: harness.identity, version: harness.session.version)
        ))
        XCTAssertTrue(harness.textView.textStorage.string.hasPrefix("![](assets/a.png)\n"))
        harness.controller.undo()
        XCTAssertEqual(harness.textView.textStorage.string, "body")

        let snapshot = try XCTUnwrap(harness.controller.captureSnapshot())
        let stale = IOSAuthorizedEdit(
            bindingID: snapshot.bindingID,
            baseRevision: snapshot.revision,
            selectionGeneration: snapshot.selectionGeneration,
            accessGeneration: snapshot.accessGeneration,
            result: MarkdownEditResult(
                replacementRange: NSRange(location: 0, length: 0),
                replacementString: "NO",
                newSelection: NSRange(location: 2, length: 0)
            ),
            undoActionName: "Stale"
        )
        let text = harness.textView.textStorage.string
        let selection = harness.textView.selectedRange
        let version = harness.session.version
        let canUndo = harness.textView.undoManager?.canUndo
        func assertUntouched(
            _ outcome: IOSEditOutcome,
            _ expected: IOSEditOutcome,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            XCTAssertEqual(outcome, expected, file: file, line: line)
            XCTAssertEqual(harness.textView.textStorage.string, text, file: file, line: line)
            XCTAssertEqual(harness.textView.selectedRange, selection, file: file, line: line)
            XCTAssertEqual(harness.session.version, version, file: file, line: line)
            XCTAssertEqual(harness.textView.undoManager?.canUndo, canUndo, file: file, line: line)
        }

        let other = IOSDocumentRevision(
            documentID: IOSDocumentIdentity(rawValue: UUID()),
            version: snapshot.revision.version
        )
        assertUntouched(harness.controller.apply(copy(stale, revision: other)), .refused(.documentChanged))
        assertUntouched(
            harness.controller.apply(copy(stale, revision: IOSDocumentRevision(
                documentID: harness.identity,
                version: snapshot.revision.version + 9
            ))),
            .refused(.sourceChanged)
        )

        harness.controller.detach(expected: harness.identity, bindingID: harness.bindingID)
        let rebound = UUID()
        harness.controller.attach(IOSSourceEditorDocumentBinding(
            bindingID: rebound,
            identity: harness.identity,
            session: harness.session,
            accessGeneration: 1,
            canWrite: true
        ))
        harness.controller.updateCommandFocus(for: harness.identity, bindingID: rebound, isFocused: true)
        // Reattach fences the previous undo groups because they addressed the old installation.
        let afterReattach = harness.textView.textStorage.string
        let afterSelection = harness.textView.selectedRange
        let afterVersion = harness.session.version
        let afterUndo = harness.textView.undoManager?.canUndo
        let outcome = harness.controller.apply(stale)
        XCTAssertEqual(outcome, .refused(.bindingChanged))
        XCTAssertEqual(harness.textView.textStorage.string, afterReattach)
        XCTAssertEqual(harness.textView.selectedRange, afterSelection)
        XCTAssertEqual(harness.session.version, afterVersion)
        XCTAssertEqual(harness.textView.undoManager?.canUndo, afterUndo)
    }

    @MainActor
    func testSelectionABAAccessReadOnlyMarkedTextFocusRangeAndBusyRefuse() throws {
        let harness = IOSEditorHarness(text: "abcdef")
        harness.textView.selectedRange = NSRange(location: 0, length: 3)
        let captured = try harness.edit(MarkdownEditResult(
            replacementRange: NSRange(location: 0, length: 3),
            replacementString: "ZZZ",
            newSelection: NSRange(location: 3, length: 0)
        ))
        harness.textView.selectedRange = NSRange(location: 3, length: 0)
        harness.textView.selectedRange = NSRange(location: 0, length: 3)
        let text = harness.textView.textStorage.string
        let selection = harness.textView.selectedRange
        let version = harness.session.version
        let canUndo = harness.textView.undoManager?.canUndo
        XCTAssertEqual(harness.controller.apply(captured), .refused(.selectionChanged))
        assertFrozen(harness, text: text, selection: selection, version: version, canUndo: canUndo)

        harness.controller.updateAccess(
            for: harness.identity,
            bindingID: harness.bindingID,
            generation: 2,
            canWrite: false
        )
        let current = try harness.edit(MarkdownEditResult(
            replacementRange: NSRange(location: 0, length: 0),
            replacementString: "Q",
            newSelection: NSRange(location: 1, length: 0)
        ))
        let staleAccess = IOSAuthorizedEdit(
            bindingID: current.bindingID,
            baseRevision: current.baseRevision,
            selectionGeneration: current.selectionGeneration,
            accessGeneration: 1,
            result: current.result,
            undoActionName: current.undoActionName
        )
        XCTAssertEqual(harness.controller.apply(staleAccess), .refused(.accessChanged))
        harness.controller.updateAccess(
            for: harness.identity,
            bindingID: harness.bindingID,
            generation: 2,
            canWrite: false
        )
        let readOnly = try harness.edit(current.result)
        XCTAssertEqual(harness.controller.apply(readOnly), .refused(.readOnly))

        harness.controller.updateAccess(
            for: harness.identity,
            bindingID: harness.bindingID,
            generation: 3,
            canWrite: true
        )
        harness.textView.setMarkedText("ㄓ", selectedRange: NSRange(location: 0, length: 1))
        XCTAssertNotNil(harness.textView.markedTextRange)
        let marked = try harness.edit(MarkdownEditResult(
            replacementRange: NSRange(location: 0, length: 0),
            replacementString: "Q",
            newSelection: NSRange(location: 1, length: 0)
        ))
        let beforeMarked = harness.textView.textStorage.string
        let beforeMarkedUndo = harness.textView.undoManager?.canUndo
        XCTAssertEqual(harness.controller.apply(marked), .refused(.markedText))
        XCTAssertEqual(harness.textView.textStorage.string, beforeMarked)
        XCTAssertEqual(harness.textView.undoManager?.canUndo, beforeMarkedUndo)
        harness.textView.unmarkText()

        let unfocused = IOSEditorHarness(text: "abc", focused: false)
        let refused = try unfocused.edit(MarkdownEditResult(
            replacementRange: NSRange(location: 0, length: 0),
            replacementString: "Z",
            newSelection: NSRange(location: 1, length: 0)
        ))
        XCTAssertEqual(unfocused.controller.apply(refused), .refused(.notFocused))
        XCTAssertEqual(unfocused.session.version, 0)

        let invalid = try harness.edit(MarkdownEditResult(
            replacementRange: NSRange(location: 50, length: 1),
            replacementString: "Z",
            newSelection: NSRange(location: 0, length: 0)
        ))
        XCTAssertEqual(harness.controller.apply(invalid), .refused(.invalidRange))

        let busyHost = IOSEditorHarness(text: "busy")
        let busyEdit = try busyHost.edit(MarkdownEditResult(
            replacementRange: NSRange(location: 0, length: 0),
            replacementString: "OK",
            newSelection: NSRange(location: 2, length: 0)
        ))
        var reentered: IOSEditOutcome?
        busyHost.controller.beforeNativeMutation = { controller in
            reentered = controller.apply(busyEdit)
        }
        XCTAssertEqual(busyHost.controller.apply(busyEdit), .applied(IOSDocumentRevision(
            documentID: busyHost.identity,
            version: busyHost.session.version
        )))
        XCTAssertEqual(reentered, .refused(.busy))
        XCTAssertEqual(busyHost.textView.textStorage.string, "OKbusy")
        busyHost.controller.undo()
        XCTAssertEqual(busyHost.textView.textStorage.string, "busy")
    }

    @MainActor
    private func assertFrozen(
        _ harness: IOSEditorHarness,
        text: String,
        selection: NSRange,
        version: Int,
        canUndo: Bool?
    ) {
        XCTAssertEqual(harness.textView.textStorage.string, text)
        XCTAssertEqual(harness.textView.selectedRange, selection)
        XCTAssertEqual(harness.session.version, version)
        XCTAssertEqual(harness.textView.undoManager?.canUndo, canUndo)
    }

    private func copy(_ edit: IOSAuthorizedEdit, revision: IOSDocumentRevision) -> IOSAuthorizedEdit {
        IOSAuthorizedEdit(
            bindingID: edit.bindingID,
            baseRevision: revision,
            selectionGeneration: edit.selectionGeneration,
            accessGeneration: edit.accessGeneration,
            result: edit.result,
            undoActionName: edit.undoActionName
        )
    }
}
