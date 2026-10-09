import Foundation
import MarkdownCore
@testable import PlainsongIOS
import XCTest

final class IOSFormattingActionTests: XCTestCase {
    @MainActor
    func testBoldEmptyCaret() throws {
        try assertMatchesPlanner(.bold, text: "hello", selection: NSRange(location: 5, length: 0), undoName: "Bold")
    }

    @MainActor
    func testBoldMultilineSelection() throws {
        try assertMatchesPlanner(.bold, text: "a\nb", selection: NSRange(location: 0, length: 3))
    }

    @MainActor
    func testBoldTraditionalChineseAndEmoji() throws {
        let text = "「測試😀」"
        let selection = NSRange(location: 0, length: (text as NSString).length)
        XCTAssertGreaterThan(selection.length, text.count)
        try assertMatchesPlanner(.bold, text: text, selection: selection)
    }

    @MainActor
    func testBoldNestedToggleRemovesDelimiter() throws {
        let text = "**word**"
        let selection = NSRange(location: 0, length: (text as NSString).length)
        try assertMatchesPlanner(.bold, text: text, selection: selection)
    }

    @MainActor
    func testItalicStrikethroughInlineCodeQuoteFenceCheckboxTableMatchPlanner() throws {
        let word = NSRange(location: 0, length: 5)
        try assertMatchesPlanner(.italic, text: "hello", selection: word)
        try assertMatchesPlanner(.strikethrough, text: "hello", selection: word)
        try assertMatchesPlanner(.inlineCode, text: "hello", selection: word)
        try assertMatchesPlanner(.code, text: "hello", selection: word)
        try assertMatchesPlanner(.quote, text: "hello", selection: word)
        try assertMatchesPlanner(.paragraph, text: "# hello", selection: word)
        try assertMatchesPlanner(.codeFence, text: "hello", selection: word)
        try assertMatchesPlanner(.checkbox, text: "- [ ] item", selection: NSRange(location: 0, length: 0))
        try assertMatchesPlanner(
            .formatTable,
            text: "| a | bb |\n| --- | --- |\n| c | d |\n",
            selection: NSRange(location: 0, length: 0)
        )
        try assertNilPlanner(.quote, text: "   ", selection: NSRange(location: 0, length: 3))
        try assertNilPlanner(.paragraph, text: "hello", selection: word)
    }

    @MainActor
    func testMathRefusalInCodeHasNoEditOrUndo() {
        let text = "```\nlet value = 1\n```\n"
        let selection = NSRange(location: 4, length: 3)
        let planned = MarkdownEditing.apply(.format(.insertInlineMath), to: text, selection: selection)
        XCTAssertNil(planned)
        let harness = AuthoringHarness(text: text, selection: selection)
        harness.controller.perform(.inlineMath, using: harness.editor)
        XCTAssertEqual(harness.editor.applyCount, 0)
        XCTAssertEqual(harness.editor.revealCalls.count, 0)
        XCTAssertEqual(harness.editor.undoCount, 0)
        XCTAssertEqual(harness.controller.statusMessage, IOSAuthoringCatalog.formattingRefusal)
        XCTAssertFalse(harness.controller.statusMessage.isEmpty)
    }

    @MainActor
    func testMathInsideFormulaRevealsWithoutApply() throws {
        let text = "$x$"
        let selection = NSRange(location: 2, length: 0)
        let planned = try XCTUnwrap(MarkdownEditing.apply(.format(.insertInlineMath), to: text, selection: selection))
        XCTAssertTrue(planned.replacementString.isEmpty)
        XCTAssertEqual(planned.replacementRange.length, 0)
        let harness = AuthoringHarness(text: text, selection: selection)
        let snapshot = try XCTUnwrap(harness.editor.captureSnapshot())
        harness.controller.perform(.inlineMath, using: harness.editor)
        XCTAssertEqual(harness.editor.applyCount, 0)
        XCTAssertEqual(harness.editor.undoCount, 0)
        let reveal = try XCTUnwrap(harness.editor.revealCalls.last)
        XCTAssertEqual(reveal.range, planned.newSelection)
        XCTAssertEqual(reveal.revision, snapshot.revision)
        XCTAssertTrue(reveal.accepted)
    }

    @MainActor
    func testDisplayMathRefusalOnListHasNoUndo() {
        let text = "- item\n"
        let planned = MarkdownEditing.apply(
            .format(.insertDisplayMath),
            to: text,
            selection: NSRange(location: 0, length: 0)
        )
        XCTAssertNil(planned)
        let harness = AuthoringHarness(text: text)
        harness.controller.perform(.displayMath, using: harness.editor)
        XCTAssertEqual(harness.editor.applyCount, 0)
        XCTAssertEqual(harness.editor.revealCalls.count, 0)
        XCTAssertEqual(harness.editor.undoCount, 0)
        XCTAssertEqual(harness.controller.statusMessage, IOSAuthoringCatalog.formattingRefusal)
    }

    @MainActor
    func testLinkSheetSubmitsCapturedGenerationsOnce() throws {
        let harness = AuthoringHarness(text: "docs", selection: NSRange(location: 0, length: 4))
        let snapshot = try XCTUnwrap(harness.editor.captureSnapshot())
        let planned = try XCTUnwrap(MarkdownEditing.apply(
            .format(.link),
            to: snapshot.document.text,
            selection: snapshot.selection
        ))
        harness.controller.perform(.link, using: harness.editor)
        harness.controller.setLinkURL("https://example.test")
        harness.controller.confirmLink(using: harness.editor)
        let edit = try XCTUnwrap(harness.editor.submitted.last)
        XCTAssertEqual(harness.editor.applyCount, 1)
        XCTAssertEqual(edit.undoActionName, "Link")
        XCTAssertEqual(edit.bindingID, snapshot.bindingID)
        XCTAssertEqual(edit.baseRevision, snapshot.revision)
        XCTAssertEqual(edit.selectionGeneration, snapshot.selectionGeneration)
        XCTAssertEqual(edit.accessGeneration, snapshot.accessGeneration)
        XCTAssertEqual(edit.result.replacementRange, planned.replacementRange)
        XCTAssertEqual(harness.editor.text, "[docs](https://example.test)")
        XCTAssertNil(harness.controller.linkDraft)
    }

    @MainActor
    func testLinkEmptyDestinationUsesPlannerResult() throws {
        let harness = AuthoringHarness(text: "docs", selection: NSRange(location: 0, length: 4))
        let snapshot = try XCTUnwrap(harness.editor.captureSnapshot())
        let planned = try XCTUnwrap(MarkdownEditing.apply(
            .format(.link),
            to: snapshot.document.text,
            selection: snapshot.selection
        ))
        harness.controller.perform(.link, using: harness.editor)
        harness.controller.confirmLink(using: harness.editor)
        let edit = try XCTUnwrap(harness.editor.submitted.last)
        XCTAssertEqual(edit.result, planned)
        XCTAssertEqual(harness.editor.applyCount, 1)
    }

    @MainActor
    func testLinkEmptySelectionInsertsLabelAndURL() {
        let harness = AuthoringHarness(text: "hello", selection: NSRange(location: 5, length: 0))
        harness.controller.perform(.link, using: harness.editor)
        XCTAssertEqual(harness.controller.linkDraft?.planned.replacementString, "[]()")
        XCTAssertEqual(harness.controller.linkDraft?.collectsLabel, true)
        harness.controller.setLinkLabel("docs")
        harness.controller.setLinkURL("https://example.test")
        harness.controller.confirmLink(using: harness.editor)
        XCTAssertEqual(harness.editor.applyCount, 1)
        XCTAssertEqual(harness.editor.text, "hello[docs](https://example.test)")
        XCTAssertEqual(harness.editor.submitted.last?.undoActionName, "Link")
    }

    @MainActor
    func testLinkUnwrapSkipsSheet() throws {
        let text = "[docs](https://example.test)"
        let selection = NSRange(location: 0, length: (text as NSString).length)
        let harness = AuthoringHarness(text: text, selection: selection)
        let planned = try XCTUnwrap(MarkdownEditing.apply(.format(.link), to: text, selection: selection))
        harness.controller.perform(.link, using: harness.editor)
        XCTAssertNil(harness.controller.linkDraft)
        XCTAssertEqual(harness.editor.applyCount, 1)
        XCTAssertEqual(harness.editor.submitted.last?.result, planned)
        XCTAssertEqual(harness.editor.submitted.last?.undoActionName, "Link")
    }

    @MainActor
    func testLinkCaretOffsetOutsideReplacementRefuses() throws {
        let harness = AuthoringHarness(text: "abcd")
        let snapshot = try XCTUnwrap(harness.editor.captureSnapshot())
        harness.controller.linkDraft = IOSLinkDraft(
            snapshot: snapshot,
            planned: MarkdownEditResult(
                replacementRange: NSRange(location: 0, length: 6),
                replacementString: "[ab]()",
                newSelection: NSRange(location: 100, length: 0)
            ),
            collectsLabel: false
        )
        harness.controller.setLinkURL("https://example.test")
        harness.controller.confirmLink(using: harness.editor)
        XCTAssertEqual(harness.editor.applyCount, 0)
        XCTAssertEqual(harness.editor.undoCount, 0)
        XCTAssertEqual(harness.controller.statusMessage, IOSAuthoringCatalog.formattingRefusal)
        XCTAssertNotNil(harness.controller.linkDraft)
    }

    @MainActor
    func testUndoActionNameMatchesDescriptorTitle() throws {
        try assertMatchesPlanner(.bold, text: "hello", selection: NSRange(location: 5, length: 0), undoName: "Bold")
        try assertMatchesPlanner(.quote, text: "hello", selection: NSRange(location: 0, length: 5), undoName: "Quote")
        try assertMatchesPlanner(
            .formatTable,
            text: "| a | bb |\n| --- | --- |\n| c | d |\n",
            selection: NSRange(location: 0, length: 0),
            undoName: "Format Table"
        )
    }

    @MainActor
    func testCatalogShortcutIdentifiersAreUnique() throws {
        var seen: [String: IOSAuthoringActionID] = [:]
        for action in IOSAuthoringCatalog.actions {
            guard let identity = IOSAuthoringCatalog.keyboardIdentity(action) else { continue }
            XCTAssertNil(seen[identity], "duplicate shortcut \(identity)")
            seen[identity] = action.id
        }
        let commandE = IOSAuthoringCatalog.actions.filter {
            $0.keyboardInput == "e" && $0.keyboardModifiers == .command
        }
        XCTAssertEqual(commandE.map(\.id), [.useSelectionForFind])
        let inlineCode = try XCTUnwrap(IOSAuthoringCatalog.actions.first { $0.id == .inlineCode })
        let code = try XCTUnwrap(IOSAuthoringCatalog.actions.first { $0.id == .code })
        XCTAssertNil(inlineCode.keyboardInput)
        XCTAssertNil(code.keyboardInput)
    }

    @MainActor
    func testToolbarContainsPrimaryActionsAndGroups() {
        let toolbar = IOSAuthoringCatalog.actions.filter {
            if case .toolbar = $0.placement { true } else { false }
        }
        XCTAssertEqual(toolbar.map(\.id), [.bold, .italic, .link])
        let headings = IOSAuthoringCatalog.actions.filter { action in
            if case let .toolbarGroup(name) = action.placement { name == "Heading" } else { false }
        }
        XCTAssertEqual(headings.map(\.id), (1 ... 6).map { IOSAuthoringActionID.heading($0) })
        let codeGroup = IOSAuthoringCatalog.actions.filter { action in
            if case let .toolbarGroup(name) = action.placement { name == "Code" } else { false }
        }
        XCTAssertEqual(codeGroup.map(\.id), [.code, .inlineCode, .codeFence])
        XCTAssertEqual(IOSAuthoringCatalog.actions.count, 24)
    }

    @MainActor
    func testAuthoringViewDoesNotInstallKeyCommands() {
        XCTAssertFalse(IOSAuthoringCatalog.installsKeyCommands)
        let harness = AuthoringHarness(text: "hello", selection: NSRange(location: 0, length: 5))
        _ = IOSAuthoringToolbar(controller: harness.controller, editor: harness.editor).body
        _ = IOSAuthoringFindBar(controller: harness.controller, editor: harness.editor).body
        _ = IOSAuthoringFrontmatterPanel(controller: harness.controller, editor: harness.editor).body
        harness.controller.perform(.bold, using: harness.editor)
        XCTAssertEqual(harness.editor.applyCount, 1)
        XCTAssertEqual(harness.editor.revealCalls.count, 0)
    }

    @MainActor
    func testStrikethroughKeepsControlCommandXUnlessC0NarrowsTheList() throws {
        let action = try XCTUnwrap(IOSAuthoringCatalog.actions.first { $0.id == .strikethrough })
        XCTAssertEqual(action.keyboardInput, "x")
        XCTAssertEqual(action.keyboardModifiers, [.control, .command])
        XCTAssertEqual(action.placement, .formatMenu)
    }

    @MainActor
    private func assertMatchesPlanner(
        _ action: IOSAuthoringActionID,
        text: String,
        selection: NSRange,
        undoName: String? = nil
    ) throws {
        let command = try XCTUnwrap(editCommand(for: action))
        let planned = try XCTUnwrap(MarkdownEditing.apply(command, to: text, selection: selection))
        XCTAssertFalse(planned.replacementString.isEmpty && planned.replacementRange.length == 0)
        let harness = AuthoringHarness(text: text, selection: selection)
        harness.controller.perform(action, using: harness.editor)
        XCTAssertEqual(harness.editor.applyCount, 1)
        XCTAssertEqual(harness.editor.submitted.last?.result, planned)
        if let undoName {
            XCTAssertEqual(harness.editor.submitted.last?.undoActionName, undoName)
            XCTAssertEqual(IOSAuthoringCatalog.title(for: action), undoName)
        }
    }

    @MainActor
    private func assertNilPlanner(_ action: IOSAuthoringActionID, text: String, selection: NSRange) throws {
        let command = try XCTUnwrap(editCommand(for: action))
        XCTAssertNil(MarkdownEditing.apply(command, to: text, selection: selection))
        let harness = AuthoringHarness(text: text, selection: selection)
        harness.controller.perform(action, using: harness.editor)
        XCTAssertEqual(harness.editor.applyCount, 0)
        XCTAssertEqual(harness.editor.revealCalls.count, 0)
        XCTAssertEqual(harness.editor.undoCount, 0)
    }

    private func editCommand(for action: IOSAuthoringActionID) -> MarkdownEditCommand? {
        switch action {
        case .bold: .format(.bold)
        case .italic: .format(.italic)
        case .code, .inlineCode: .format(.inlineCode)
        case .strikethrough: .format(.strikethrough)
        case let .heading(level): .format(.heading(level: level))
        case .paragraph: .format(.paragraph)
        case .quote: .format(.quote)
        case .codeFence: .format(.codeFence)
        case .inlineMath: .format(.insertInlineMath)
        case .displayMath: .format(.insertDisplayMath)
        case .checkbox: .toggleCheckbox
        case .formatTable: .formatTable
        case .link, .find, .nextMatch, .previousMatch, .useSelectionForFind, .singleReplace:
            nil
        }
    }
}
