import AppKit
@testable import EditorKit
import STTextView
import XCTest

@MainActor
final class WYSIWYGNativeInteractionGateTests: XCTestCase {
    func testNativeArrowLandingInsideFoldedDelimiterRevealsInsteadOfTrapping() throws {
        let source = "A **bold** and `code` done"
        let textView = makeWYSIWYGTextView(source: source)

        let outsideSelection = NSRange(location: 0, length: 0)
        XCTAssertTrue(applyProductionPresentation(source, selection: outsideSelection, revision: 1, to: textView))
        assertDelimiterFoldState(
            in: textView,
            delimiters: Self.delimiters(in: source, span: "**bold**", marker: "**"),
            isFolded: true
        )

        textView.textSelection = NSRange(location: source.nsRange(of: "**bold**").location, length: 0)
        textView.moveRight(nil)

        let arrowSelection = textView.selectedRange()
        XCTAssertEqual(
            arrowSelection,
            NSRange(location: source.nsRange(of: "**bold**").location + 1, length: 0)
        )
        let arrowPresentation = productionPresentation(source, selection: arrowSelection, revision: 2)
        XCTAssertTrue(try XCTUnwrap(arrowPresentation.foldPlan).onlyRegion(kind: .strong).isRevealed)
        XCTAssertTrue(MarkdownTextView.applyHighlightedText(arrowPresentation, to: textView))
        XCTAssertEqual(textView.selectedRange(), arrowSelection)
        assertDelimiterFoldState(
            in: textView,
            delimiters: Self.delimiters(in: source, span: "**bold**", marker: "**"),
            isFolded: false
        )
    }

    func testReverseShiftSelectionAcrossFoldedStrikeKeepsRawRangeAndRevealStateSane() throws {
        let source = "A **bold** then ~~gone~~ and `code` done"
        let textView = makeWYSIWYGTextView(source: source)
        textView.textSelection = NSRange(location: 0, length: 0)
        XCTAssertTrue(applyProductionPresentation(
            source,
            selection: textView.selectedRange(),
            revision: 1,
            to: textView
        ))

        let strikeRange = source.nsRange(of: "~~gone~~")
        textView.textSelection = NSRange(location: NSMaxRange(strikeRange), length: 0)
        for _ in 0 ..< strikeRange.length {
            textView.moveLeftAndModifySelection(nil)
            XCTAssertTrue(applyProductionPresentation(
                source,
                selection: textView.selectedRange(),
                revision: 2,
                to: textView
            ))
        }

        XCTAssertEqual(textView.selectedRange(), strikeRange)
        XCTAssertEqual(source.substring(with: textView.selectedRange()), "~~gone~~")

        let presentation = productionPresentation(source, selection: textView.selectedRange(), revision: 3)
        XCTAssertTrue(try XCTUnwrap(presentation.foldPlan).onlyRegion(kind: .strikethrough).isRevealed)
        XCTAssertTrue(MarkdownTextView.applyHighlightedText(presentation, to: textView))
        assertDelimiterFoldState(
            in: textView,
            delimiters: Self.delimiters(in: source, span: "~~gone~~", marker: "~~"),
            isFolded: false
        )

        let pasteboard = uniquePasteboard()
        XCTAssertTrue(textView.writeSelection(to: pasteboard, types: [.string]))
        XCTAssertEqual(pasteboard.string(forType: .string), "~~gone~~")
    }

    func testNativeShiftSelectionAcrossFoldedBoldStrikeAndInlineCodeCopiesRawMarkdown() throws {
        let source = "A **bold** then ~~gone~~ and `code` done"
        let textView = makeWYSIWYGTextView(source: source)
        textView.textSelection = NSRange(location: 0, length: 0)
        XCTAssertTrue(applyProductionPresentation(
            source,
            selection: textView.selectedRange(),
            revision: 1,
            to: textView
        ))

        let boldRange = source.nsRange(of: "**bold**")
        let codeRange = source.nsRange(of: "`code`")
        let selectedRange = NSRange(
            location: boldRange.location,
            length: NSMaxRange(codeRange) - boldRange.location
        )
        textView.textSelection = NSRange(location: selectedRange.location, length: 0)

        for _ in 0 ..< selectedRange.length {
            textView.moveRightAndModifySelection(nil)
            XCTAssertTrue(applyProductionPresentation(
                source,
                selection: textView.selectedRange(),
                revision: 2,
                to: textView
            ))
        }

        XCTAssertEqual(textView.selectedRange(), selectedRange)
        let selectedSource = source.substring(with: selectedRange)
        XCTAssertEqual(selectedSource, "**bold** then ~~gone~~ and `code`")

        let presentation = productionPresentation(source, selection: textView.selectedRange(), revision: 3)
        let foldPlan = try XCTUnwrap(presentation.foldPlan)
        XCTAssertTrue(try foldPlan.onlyRegion(kind: .strong).isRevealed)
        XCTAssertTrue(try foldPlan.onlyRegion(kind: .strikethrough).isRevealed)
        XCTAssertTrue(try foldPlan.onlyRegion(kind: .inlineCode).isRevealed)

        let pasteboard = uniquePasteboard()
        XCTAssertTrue(textView.writeSelection(to: pasteboard, types: [.string]))
        XCTAssertEqual(pasteboard.string(forType: .string), selectedSource)
    }

    func testMouseLikeBoundaryCaretsRecomputeFoldedStateFromRawSelection() throws {
        let source = "# Heading\n\nA **bold** and `code` done"
        let boldRange = source.nsRange(of: "**bold**")
        let codeRange = source.nsRange(of: "`code`")
        let headingMarker = source.nsRange(of: "# ")

        try assertCaretPresentation(
            source: source,
            selection: NSRange(location: NSMaxRange(headingMarker), length: 0),
            kind: .heading(level: 1),
            delimiters: [headingMarker],
            isRevealed: true
        )
        try assertCaretPresentation(
            source: source,
            selection: NSRange(location: source.nsRange(of: "A **bold**").location, length: 0),
            kind: .heading(level: 1),
            delimiters: [headingMarker],
            isRevealed: false
        )
        try assertCaretPresentation(
            source: source,
            selection: NSRange(location: boldRange.location, length: 0),
            kind: .strong,
            delimiters: Self.delimiters(in: source, span: "**bold**", marker: "**"),
            isRevealed: true
        )
        try assertCaretPresentation(
            source: source,
            selection: NSRange(location: NSMaxRange(boldRange), length: 0),
            kind: .strong,
            delimiters: Self.delimiters(in: source, span: "**bold**", marker: "**"),
            isRevealed: false
        )
        try assertCaretPresentation(
            source: source,
            selection: NSRange(location: codeRange.location, length: 0),
            kind: .inlineCode,
            delimiters: Self.delimiters(in: source, span: "`code`", marker: "`"),
            isRevealed: true
        )
        try assertCaretPresentation(
            source: source,
            selection: NSRange(location: NSMaxRange(codeRange), length: 0),
            kind: .inlineCode,
            delimiters: Self.delimiters(in: source, span: "`code`", marker: "`"),
            isRevealed: false
        )
    }

    func testPartialFoldedSpanCopyPolicyUsesExactRawSelection() {
        let source = "A **bold** and `code` plus ~~gone~~."
        let textView = makeWYSIWYGTextView(source: source)
        XCTAssertTrue(applyProductionPresentation(
            source,
            selection: NSRange(location: 0, length: 0),
            revision: 1,
            to: textView
        ))

        let boldRange = source.nsRange(of: "**bold**")
        let boldContentRange = source.nsRange(of: "bold")
        let codeRange = source.nsRange(of: "`code`")
        let strikeRange = source.nsRange(of: "~~gone~~")

        assertCopy(source: source, range: boldRange, equals: "**bold**", in: textView)
        assertCopy(source: source, range: boldContentRange, equals: "bold", in: textView)
        assertCopy(
            source: source,
            range: NSRange(location: boldRange.location, length: 4),
            equals: "**bo",
            in: textView
        )
        assertCopy(
            source: source,
            range: NSRange(location: boldContentRange.location, length: boldContentRange.length + 2),
            equals: "bold**",
            in: textView
        )
        assertCopy(source: source, range: codeRange, equals: "`code`", in: textView)
        assertCopy(source: source, range: strikeRange, equals: "~~gone~~", in: textView)
    }

    func testPasteIntoFoldedAndRevealedRegionsMutatesBackingSourceOnly() {
        let source = "A **bold** and `code` done"
        let textView = makeWYSIWYGTextView(source: source)
        XCTAssertTrue(applyProductionPresentation(
            source,
            selection: NSRange(location: 0, length: 0),
            revision: 1,
            to: textView
        ))

        textView.textSelection = NSRange(location: source.nsRange(of: "**bold**").location, length: 0)
        let boundaryPasteboard = uniquePasteboard()
        boundaryPasteboard.setString("X", forType: .string)
        XCTAssertTrue(textView.readSelection(from: boundaryPasteboard, type: .string))

        let pastedAtFoldBoundary = "A X**bold** and `code` done"
        XCTAssertEqual(Self.text(in: textView), pastedAtFoldBoundary)
        XCTAssertFalse(Self.text(in: textView).contains("\u{fffc}"))
        XCTAssertTrue(applyProductionPresentation(
            pastedAtFoldBoundary,
            selection: textView.selectedRange(),
            revision: 2,
            to: textView
        ))

        let codeContentRange = pastedAtFoldBoundary.nsRange(of: "code")
        textView.textSelection = NSRange(location: codeContentRange.location + 1, length: 2)
        let revealedPasteboard = uniquePasteboard()
        revealedPasteboard.setString("XX", forType: .string)
        XCTAssertTrue(textView.readSelection(from: revealedPasteboard, type: .string))

        XCTAssertEqual(Self.text(in: textView), "A X**bold** and `cXXe` done")
        XCTAssertFalse(Self.text(in: textView).contains("\u{fffc}"))
    }

    func testAccessibilityValueRemainsRawMarkdownSource() {
        let source = "# Heading\n\nA **bold** and `code` plus ~~gone~~."
        let textView = makeWYSIWYGTextView(source: source)
        XCTAssertTrue(applyProductionPresentation(
            source,
            selection: NSRange(location: 0, length: 0),
            revision: 1,
            to: textView
        ))

        XCTAssertEqual(textView.accessibilityRole(), .textArea)
        XCTAssertEqual(textView.accessibilityValue() as? String, source)
        XCTAssertFalse((textView.accessibilityValue() as? String)?.contains("\u{fffc}") ?? true)
    }
}

@MainActor
private extension WYSIWYGNativeInteractionGateTests {
    func productionPresentation(_ source: String, selection: NSRange, revision: Int) -> HighlightedText {
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

    @discardableResult
    func applyProductionPresentation(
        _ source: String,
        selection: NSRange,
        revision: Int,
        to textView: STTextView
    ) -> Bool {
        MarkdownTextView.applyHighlightedText(
            productionPresentation(source, selection: selection, revision: revision),
            to: textView
        )
    }

    func assertCaretPresentation(
        source: String,
        selection: NSRange,
        kind: WYSIWYGFoldRegion.Kind,
        delimiters: [NSRange],
        isRevealed: Bool
    ) throws {
        let textView = makeWYSIWYGTextView(source: source)
        textView.textSelection = selection

        let presentation = productionPresentation(source, selection: selection, revision: 1)
        XCTAssertEqual(
            try XCTUnwrap(presentation.foldPlan).onlyRegion(kind: kind).isRevealed,
            isRevealed
        )
        XCTAssertTrue(MarkdownTextView.applyHighlightedText(presentation, to: textView))
        XCTAssertEqual(textView.selectedRange(), selection)
        assertDelimiterFoldState(
            in: textView,
            delimiters: delimiters,
            isFolded: !isRevealed
        )
    }

    func assertDelimiterFoldState(
        in textView: STTextView,
        delimiters: [NSRange],
        isFolded: Bool
    ) {
        guard let textStorage = MarkdownTextView.textStorage(of: textView) else {
            XCTFail("Expected text storage")
            return
        }

        for delimiter in delimiters {
            let attributes = textStorage.attributes(at: delimiter.location, effectiveRange: nil)
            XCTAssertEqual(
                WYSIWYGInlineFoldPresentation.containsFoldedDelimiterAttributes(attributes),
                isFolded,
                "Unexpected fold state for delimiter \(delimiter)"
            )
        }
    }

    func assertCopy(
        source: String,
        range: NSRange,
        equals expected: String,
        in textView: STTextView
    ) {
        textView.textSelection = range
        let pasteboard = uniquePasteboard()
        XCTAssertTrue(textView.writeSelection(to: pasteboard, types: [.string]))
        XCTAssertEqual(pasteboard.string(forType: .string), expected)
        XCTAssertEqual(source.substring(with: range), expected)
    }

    static func delimiters(in source: String, span: String, marker: String) -> [NSRange] {
        [
            source.nsRange(of: span, selecting: marker),
            source.nsRange(of: span, selectingLast: marker),
        ]
    }

    static func text(in textView: STTextView) -> String {
        MarkdownTextView.textStorage(of: textView)?.string ?? textView.text ?? ""
    }

    func uniquePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PlainsongNativeGate.\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    func makeWYSIWYGTextView(source: String) -> MarkdownSTTextView {
        let textView = MarkdownSTTextView(frame: .zero)
        textView.font = MarkdownSyntaxHighlighter.defaultFont
        textView.text = source
        textView.setWYSIWYGZeroWidthFoldingEnabled(true)
        return textView
    }
}

private extension WYSIWYGFoldPlan {
    func onlyRegion(kind: WYSIWYGFoldRegion.Kind) throws -> WYSIWYGFoldRegion {
        let matchingRegions = regions.filter { $0.kind == kind }
        XCTAssertEqual(matchingRegions.count, 1)
        return try XCTUnwrap(matchingRegions.first)
    }
}

private extension String {
    func nsRange(of substring: String) -> NSRange {
        let range = (self as NSString).range(of: substring)
        XCTAssertNotEqual(range.location, NSNotFound, "Expected substring '\(substring)' in '\(self)'")
        return range
    }

    func nsRange(of containingSubstring: String, selecting selectedSubstring: String) -> NSRange {
        let containerRange = nsRange(of: containingSubstring)
        let container = (self as NSString).substring(with: containerRange) as NSString
        let selectedRange = container.range(of: selectedSubstring)
        XCTAssertNotEqual(
            selectedRange.location,
            NSNotFound,
            "Expected substring '\(selectedSubstring)' in '\(containingSubstring)'"
        )
        return NSRange(location: containerRange.location + selectedRange.location, length: selectedRange.length)
    }

    func nsRange(of containingSubstring: String, selectingLast selectedSubstring: String) -> NSRange {
        let containerRange = nsRange(of: containingSubstring)
        let container = (self as NSString).substring(with: containerRange) as NSString
        let selectedRange = container.range(of: selectedSubstring, options: .backwards)
        XCTAssertNotEqual(
            selectedRange.location,
            NSNotFound,
            "Expected substring '\(selectedSubstring)' in '\(containingSubstring)'"
        )
        return NSRange(location: containerRange.location + selectedRange.location, length: selectedRange.length)
    }

    func substring(with range: NSRange) -> String {
        (self as NSString).substring(with: range)
    }
}
