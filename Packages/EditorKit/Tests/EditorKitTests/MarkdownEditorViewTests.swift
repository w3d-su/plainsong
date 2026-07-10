import AppKit
@testable import EditorKit
import STTextView
import XCTest

final class MarkdownEditorViewTests: XCTestCase {
    func testComputedHighlightCoversTypicalDocuments() {
        XCTAssertTrue(MarkdownEditorView.shouldComputeHighlight(forLength: 0))
        XCTAssertTrue(
            MarkdownEditorView.shouldComputeHighlight(
                forLength: MarkdownEditorView.maxComputedHighlightLength
            )
        )
    }

    func testComputedHighlightStillRunsForVeryLargeDocuments() {
        XCTAssertTrue(
            MarkdownEditorView.shouldComputeHighlight(
                forLength: MarkdownEditorView.maxComputedHighlightLength + 1
            )
        )
    }

    func testHighlightedTextEqualityIsByRevisionOnly() {
        let first = HighlightedText(revision: 1, text: AttributedString("a"))
        let sameRevision = HighlightedText(revision: 1, text: AttributedString("b"))
        let nextRevision = HighlightedText(revision: 2, text: AttributedString("a"))

        XCTAssertEqual(first, sameRevision, "SwiftUI prop diffing must stay O(1) by revision")
        XCTAssertNotEqual(first, nextRevision)
    }

    func testEditorFontUsesConfiguredFamilyAndFallback() {
        let menlo = MarkdownSyntaxHighlighter.editorFont(named: "Menlo", size: 15)
        XCTAssertEqual(menlo.pointSize, 15)

        let fallback = MarkdownSyntaxHighlighter.editorFont(named: "Definitely Missing Font", size: 17)
        XCTAssertEqual(fallback.pointSize, 17)
        XCTAssertTrue(fallback.fontDescriptor.symbolicTraits.contains(.monoSpace))
    }

    func testBuiltInEditorThemesAreAvailable() {
        XCTAssertEqual(MarkdownEditorTheme.allCases.map(\.displayName), ["Plainsong", "Graphite"])

        let graphite = MarkdownSyntaxTheme.builtIn(.graphite)
        XCTAssertNotEqual(graphite.listMarkerColor, MarkdownSyntaxTheme.standard.listMarkerColor)
    }

    func testHighlightSchedulingDebouncesAndDropsStaleRevisions() async {
        XCTAssertGreaterThan(MarkdownEditorView.highlightDebounceNanoseconds, 0)

        let latestRevision = HighlightRevisionProbe()
        let starts = HighlightStartProbe()
        await withTaskGroup(of: Void.self) { group in
            for revision in 1 ... 5 {
                await latestRevision.set(revision)
                group.addTask {
                    let debounceCompleted = await MarkdownEditorView.waitForHighlightDebounce(nanoseconds: 10_000_000)
                    let currentRevision = await latestRevision.current()
                    guard debounceCompleted,
                          MarkdownEditorView.shouldApplyScheduledHighlight(
                              revision: revision,
                              currentRevision: currentRevision,
                              taskIsCancelled: Task.isCancelled
                          )
                    else {
                        return
                    }

                    await starts.record(revision)
                }
            }
        }

        let recordedRevisions = await starts.recordedRevisions()
        XCTAssertEqual(
            recordedRevisions,
            [5],
            "Rapid typing should let only the latest revision reach parser work."
        )
    }

    func testHighlightRequestFallsBackToSelectionWindowWhenViewportIsEmpty() {
        let range = MarkdownEditorView.highlightRequestRange(
            textLength: 50000,
            visibleRange: NSRange(location: 0, length: 0),
            selection: NSRange(location: 20000, length: 0)
        )

        XCTAssertEqual(range.location, 20000)
        XCTAssertEqual(range.length, MarkdownSyntaxParser.visibleHighlightMinimumLength)
    }

    @MainActor
    func testWYSIWYGVisibleRangeFoldRecomputeStaysUnderHighlightBudget() async throws {
        let fixtureText = try String(contentsOf: Self.repoRoot.appending(path: "Fixtures/large-1mb.md"))
        let foldedLine = "\nVisible **bold** and *italic* with ~~gone~~ plus `code`.\n"
        let source = fixtureText + foldedLine
        let visibleRange = (source as NSString).range(of: "Visible **bold**")
        let editLocation = NSMaxRange((source as NSString).range(of: "Visible"))

        let result = try await EditorPerformanceProbe.measureVisibleRangeHighlightUpdate(
            fixtureText: source,
            fileKind: .markdown,
            visibleRange: visibleRange,
            editLocation: editLocation,
            insertion: "!",
            developmentPresentation: .inlineFoldReveal
        )

        print(String(
            format: "WYSIWYG visible-range fold highlight/apply: %.3f ms",
            result.elapsedMilliseconds
        ))
        XCTAssertTrue(result.didApplyHighlight)
        assertPerformanceBudget(
            result.elapsedMilliseconds,
            lessThanOrEqualTo: 50,
            metric: "WYSIWYG visible-range fold highlight/apply"
        )
        XCTAssertEqual(result.selectionAfterApply.location, editLocation + 1)
    }

    @MainActor
    func testPartialHighlightApplyPreservesTextAndSelection() {
        let source = "# Heading\n\nPlain **bold** text\n"
        let textView = STTextView(frame: .zero)
        textView.text = source
        textView.textSelection = NSRange(location: 4, length: 3)
        let highlighted = MarkdownSyntaxHighlighter().highlight(
            source,
            fileKind: .markdown,
            visibleRange: NSRange(location: 0, length: source.utf16.count)
        )

        let didApply = MarkdownTextView.applyHighlightedText(
            HighlightedText(revision: 1, range: highlighted.range, text: highlighted.text),
            to: textView
        )

        XCTAssertTrue(didApply)
        XCTAssertEqual(MarkdownTextView.textStorage(of: textView)?.string, source)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 4, length: 3))
    }

    @MainActor
    func testAttributeOnlyPresentationDoesNotEnterUndoOrRedoStack() throws {
        let source = "Intro **bold** tail\n"
        let insertionLocation = NSMaxRange((source as NSString).range(of: "bold"))
        let originalSelection = NSRange(location: insertionLocation, length: 0)
        let editedSource = "Intro **bold!** tail\n"
        let editedSelection = NSRange(location: insertionLocation + 1, length: 0)
        let redoSelection = NSRange(location: insertionLocation, length: 1)
        let textView = STTextView(frame: .zero)
        textView.text = source
        textView.textSelection = originalSelection
        let undoManager = try XCTUnwrap(textView.undoManager)
        undoManager.removeAllActions()

        textView.insertText("!", replacementRange: textView.selectedRange())
        XCTAssertEqual(MarkdownTextView.textStorage(of: textView)?.string, editedSource)
        XCTAssertEqual(textView.selectedRange(), editedSelection)

        let editedPresentation = Self.highlightedText(editedSource, revision: 1)
        XCTAssertTrue(MarkdownTextView.applyHighlightedText(editedPresentation, to: textView))
        XCTAssertEqual(textView.selectedRange(), editedSelection)

        undoManager.undo()
        XCTAssertEqual(MarkdownTextView.textStorage(of: textView)?.string, source)
        XCTAssertEqual(textView.selectedRange(), originalSelection)

        XCTAssertFalse(
            MarkdownTextView.applyHighlightedText(editedPresentation, to: textView),
            "Presentation for stale text must be recomputed after undo instead of replayed from undo state."
        )
        XCTAssertTrue(MarkdownTextView.applyHighlightedText(Self.highlightedText(source, revision: 2), to: textView))
        XCTAssertEqual(textView.selectedRange(), originalSelection)
        XCTAssertTrue(undoManager.canRedo)

        undoManager.redo()
        XCTAssertEqual(MarkdownTextView.textStorage(of: textView)?.string, editedSource)
        XCTAssertEqual(textView.selectedRange(), redoSelection)

        XCTAssertTrue(MarkdownTextView.applyHighlightedText(
            Self.highlightedText(editedSource, revision: 3),
            to: textView
        ))
        XCTAssertEqual(MarkdownTextView.textStorage(of: textView)?.string, editedSource)
        XCTAssertEqual(textView.selectedRange(), redoSelection)
    }

    @MainActor
    func testWYSIWYGUndoRecomputesFoldRevealStateWithoutUndoingPresentation() throws {
        let initialSource = "Intro **bold** tail\n"
        let textView = STTextView(frame: .zero)
        textView.text = initialSource
        let undoManager = try XCTUnwrap(textView.undoManager)
        undoManager.removeAllActions()

        textView.textSelection = NSRange(location: NSMaxRange(initialSource.nsRange(of: "Intro")), length: 0)
        textView.insertText("!", replacementRange: textView.selectedRange())

        let typedSource = "Intro! **bold** tail\n"
        let typedSelection = NSRange(location: NSMaxRange(typedSource.nsRange(of: "Intro!")), length: 0)
        XCTAssertEqual(Self.text(in: textView), typedSource)
        XCTAssertEqual(textView.selectedRange(), typedSelection)

        let parser = try WYSIWYGFoldParser()
        let outsideSelection = NSRange(location: 0, length: 0)
        textView.textSelection = outsideSelection
        let foldedPlan = Self.foldPlan(parser: parser, source: typedSource, selection: outsideSelection)
        XCTAssertEqual(typedSource.substrings(with: foldedPlan.foldedRanges), ["**", "**"])
        XCTAssertFalse(try foldedPlan.onlyRegion(kind: .strong).isRevealed)
        XCTAssertTrue(MarkdownTextView.applyHighlightedText(
            Self.wysiwygPresentation(typedSource, selection: outsideSelection, revision: 10),
            to: textView
        ))
        XCTAssertEqual(Self.text(in: textView), typedSource)
        XCTAssertEqual(textView.selectedRange(), outsideSelection)
        XCTAssertTrue(undoManager.canUndo)

        let revealSelection = NSRange(location: NSMaxRange(typedSource.nsRange(of: "bold")), length: 0)
        textView.textSelection = revealSelection
        let revealedPlan = Self.foldPlan(parser: parser, source: typedSource, selection: revealSelection)
        XCTAssertTrue(try revealedPlan.onlyRegion(kind: .strong).isRevealed)
        XCTAssertEqual(revealedPlan.foldedRanges, [])
        XCTAssertTrue(MarkdownTextView.applyHighlightedText(
            Self.wysiwygPresentation(typedSource, selection: revealSelection, revision: 11),
            to: textView
        ))
        XCTAssertEqual(textView.selectedRange(), revealSelection)
        XCTAssertTrue(undoManager.canUndo)

        textView.insertText("!", replacementRange: textView.selectedRange())

        let editedSource = "Intro! **bold!** tail\n"
        let editedSelection = NSRange(location: revealSelection.location + 1, length: 0)
        XCTAssertEqual(Self.text(in: textView), editedSource)
        XCTAssertEqual(textView.selectedRange(), editedSelection)

        let editedPlan = Self.foldPlan(parser: parser, source: editedSource, selection: editedSelection)
        XCTAssertTrue(try editedPlan.onlyRegion(kind: .strong).isRevealed)
        XCTAssertEqual(editedPlan.foldedRanges, [])
        XCTAssertTrue(MarkdownTextView.applyHighlightedText(
            Self.wysiwygPresentation(editedSource, selection: editedSelection, revision: 12),
            to: textView
        ))
        XCTAssertEqual(textView.selectedRange(), editedSelection)

        for revision in 13 ... 14 {
            undoManager.undo()
            XCTAssertEqual(Self.text(in: textView), typedSource)
            XCTAssertEqual(textView.selectedRange(), revealSelection)

            let undoPlan = Self.foldPlan(parser: parser, source: typedSource, selection: textView.selectedRange())
            XCTAssertTrue(try undoPlan.onlyRegion(kind: .strong).isRevealed)
            XCTAssertEqual(undoPlan.foldedRanges, [])
            XCTAssertTrue(MarkdownTextView.applyHighlightedText(
                Self.wysiwygPresentation(typedSource, selection: textView.selectedRange(), revision: revision),
                to: textView
            ))
            XCTAssertEqual(Self.text(in: textView), typedSource)
            XCTAssertEqual(textView.selectedRange(), revealSelection)
            XCTAssertTrue(undoManager.canRedo)

            undoManager.redo()
            let redoSelection = NSRange(location: revealSelection.location, length: 1)
            XCTAssertEqual(Self.text(in: textView), editedSource)
            XCTAssertEqual(textView.selectedRange(), redoSelection)

            let redoPlan = Self.foldPlan(parser: parser, source: editedSource, selection: redoSelection)
            XCTAssertTrue(try redoPlan.onlyRegion(kind: .strong).isRevealed)
            XCTAssertEqual(redoPlan.foldedRanges, [])
            XCTAssertTrue(MarkdownTextView.applyHighlightedText(
                Self.wysiwygPresentation(editedSource, selection: redoSelection, revision: revision + 10),
                to: textView
            ))
            XCTAssertEqual(Self.text(in: textView), editedSource)
            XCTAssertEqual(textView.selectedRange(), redoSelection)
        }
    }

    @MainActor
    func testPartialHighlightApplySkipsWhileMarkedTextExists() {
        let textView = STTextView(frame: .zero)
        textView.text = "# Heading\n"
        textView.textSelection = NSRange(location: 0, length: 0)
        textView.setMarkedText(
            "ㄓ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        let didApply = MarkdownTextView.applyHighlightedText(
            HighlightedText(revision: 1, range: NSRange(location: 0, length: 0), text: AttributedString("")),
            to: textView
        )

        XCTAssertFalse(didApply)
        XCTAssertTrue(textView.hasMarkedText())
    }

    func testTextViewUpdateSkipsIncomingTextWhileMarkedTextExists() {
        let policy = MarkdownTextViewUpdatePolicy(
            isUserEditing: false,
            hasMarkedText: true,
            incomingTextEqualsCurrentText: false
        )

        XCTAssertFalse(policy.shouldApplyIncomingText)
    }

    func testTextViewUpdateSkipsIncomingTextAfterUserEditingWhenTextAlreadyMatches() {
        let policy = MarkdownTextViewUpdatePolicy(
            isUserEditing: true,
            hasMarkedText: false,
            incomingTextEqualsCurrentText: true
        )

        XCTAssertFalse(policy.shouldApplyIncomingText)
    }

    func testTextViewUpdateDoesNotCompareIncomingTextWhenUserEditingAlreadySkips() {
        var comparisonCount = 0
        func compareIncomingText() -> Bool {
            comparisonCount += 1
            return false
        }

        let policy = MarkdownTextViewUpdatePolicy(
            isUserEditing: true,
            hasMarkedText: false,
            incomingTextEqualsCurrentText: compareIncomingText()
        )

        XCTAssertFalse(policy.shouldApplyIncomingText)
        XCTAssertEqual(comparisonCount, 0)
    }

    func testTextViewUpdateDoesNotCompareIncomingTextWhenMarkedTextAlreadySkips() {
        var comparisonCount = 0
        func compareIncomingText() -> Bool {
            comparisonCount += 1
            return false
        }

        let policy = MarkdownTextViewUpdatePolicy(
            isUserEditing: false,
            hasMarkedText: true,
            incomingTextEqualsCurrentText: compareIncomingText()
        )

        XCTAssertFalse(policy.shouldApplyIncomingText)
        XCTAssertEqual(comparisonCount, 0)
    }

    func testTextViewUpdateAppliesDifferentExternalTextWhenCompositionIsInactive() {
        let policy = MarkdownTextViewUpdatePolicy(
            isUserEditing: false,
            hasMarkedText: false,
            incomingTextEqualsCurrentText: false
        )

        XCTAssertTrue(policy.shouldApplyIncomingText)
    }

    func testEditorScrollLineIndexMapsUTF16OffsetsAndLines() {
        let index = EditorScrollLineIndex(text: "one\nemoji 🧪\nthree")

        XCTAssertEqual(index.oneBasedLine(containingUTF16Offset: 0), 1)
        XCTAssertEqual(index.oneBasedLine(containingUTF16Offset: 4), 2)
        XCTAssertEqual(index.oneBasedLine(containingUTF16Offset: 13), 3)
        XCTAssertEqual(index.utf16Offset(forOneBasedLine: 1), 0)
        XCTAssertEqual(index.utf16Offset(forOneBasedLine: 2), 4)
        XCTAssertEqual(index.utf16Offset(forOneBasedLine: 3), 13)
        XCTAssertEqual(index.utf16Offset(forOneBasedLine: 99), "one\nemoji 🧪\nthree".utf16.count)
    }

    @MainActor
    func testEditorScrollProxyEmitsLineContainingSelectionOffset() {
        let textView = STTextView(frame: .zero)
        textView.text = "one\ntwo\nthree\n"
        let otherTextView = STTextView(frame: .zero)
        otherTextView.text = textView.text
        let proxy = EditorScrollProxy()
        var emittedLines: [Int] = []
        proxy.onVisibleLineChanged = { emittedLines.append($0) }
        proxy.attach(to: textView)
        emittedLines.removeAll()

        proxy.emitVisibleLine(containingUTF16Offset: "one\ntwo\n".utf16.count, in: textView)
        proxy.emitVisibleLine(containingUTF16Offset: "one\ntwo\n".utf16.count, in: textView)
        proxy.emitVisibleLine(containingUTF16Offset: 0, in: otherTextView)

        XCTAssertEqual(emittedLines, [3])
    }
}

private actor HighlightRevisionProbe {
    private var revision = 0

    func set(_ revision: Int) {
        self.revision = revision
    }

    func current() -> Int {
        revision
    }
}

private actor HighlightStartProbe {
    private var revisions: [Int] = []

    func record(_ revision: Int) {
        revisions.append(revision)
    }

    func recordedRevisions() -> [Int] {
        revisions
    }
}

private extension MarkdownEditorViewTests {
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static func highlightedText(_ source: String, revision: Int) -> HighlightedText {
        let highlighted = MarkdownSyntaxHighlighter().highlight(
            source,
            fileKind: .markdown,
            visibleRange: NSRange(location: 0, length: source.utf16.count)
        )
        return HighlightedText(revision: revision, range: highlighted.range, text: highlighted.text)
    }

    static func wysiwygPresentation(_ source: String, selection: NSRange, revision: Int) -> HighlightedText {
        let highlighted = MarkdownSyntaxHighlighter().highlight(
            source,
            fileKind: .markdown,
            visibleRange: NSRange(location: 0, length: (source as NSString).length),
            developmentPresentation: .inlineFoldReveal,
            selection: selection
        )
        return HighlightedText(
            revision: revision,
            range: highlighted.range,
            text: highlighted.text,
            foldPlan: highlighted.foldPlan
        )
    }

    static func foldPlan(parser: WYSIWYGFoldParser, source: String, selection: NSRange) -> WYSIWYGFoldPlan {
        parser.foldPlan(
            in: source,
            fileKind: .markdown,
            visibleRange: NSRange(location: 0, length: (source as NSString).length),
            selection: selection
        )
    }

    @MainActor
    static func text(in textView: STTextView) -> String {
        MarkdownTextView.textStorage(of: textView)?.string ?? textView.text ?? ""
    }
}

private extension WYSIWYGFoldPlan {
    func onlyRegion(
        kind: WYSIWYGFoldRegion.Kind,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> WYSIWYGFoldRegion {
        let matchingRegions = regions.filter { $0.kind == kind }
        XCTAssertEqual(matchingRegions.count, 1, file: file, line: line)
        return try XCTUnwrap(matchingRegions.first, file: file, line: line)
    }
}

private extension String {
    func nsRange(of substring: String) -> NSRange {
        let range = (self as NSString).range(of: substring)
        XCTAssertNotEqual(range.location, NSNotFound, "Expected to find substring '\(substring)'")
        return range
    }

    func substring(with range: NSRange) -> String {
        (self as NSString).substring(with: range)
    }

    func substrings(with ranges: [NSRange]) -> [String] {
        ranges.map { substring(with: $0) }
    }
}
