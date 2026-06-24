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
