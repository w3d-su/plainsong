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

    func testFoldedDelimiterMetadataUsesInternalAttributeInsteadOfToolTip() {
        let source = "A **bold** and `code` done"
        let textView = makeWYSIWYGTextView(source: source)
        XCTAssertTrue(applyProductionPresentation(
            source,
            selection: NSRange(location: 0, length: 0),
            revision: 1,
            to: textView
        ))

        guard let textStorage = MarkdownTextView.textStorage(of: textView) else {
            XCTFail("Expected text storage")
            return
        }

        let delimiters = Self.delimiters(in: source, span: "**bold**", marker: "**")
            + Self.delimiters(in: source, span: "`code`", marker: "`")
        for delimiter in delimiters {
            let attributes = textStorage.attributes(at: delimiter.location, effectiveRange: nil)
            XCTAssertTrue(WYSIWYGInlineFoldPresentation.containsFoldedDelimiterAttributes(attributes))
            XCTAssertEqual(
                attributes[WYSIWYGInlineFoldPresentation.foldedDelimiterAttribute] as? Bool,
                true
            )
            XCTAssertNil(attributes[.toolTip], "Fold markers must not use tooltip metadata")
        }
    }

    func testZeroWidthDelegateRestoresPreviousDelegateWhenDisabled() throws {
        let textView = MarkdownSTTextView(frame: .zero)
        textView.text = "plain paragraph"
        let textContentStorage = try XCTUnwrap(textView.textContentManager as? NSTextContentStorage)
        let previousDelegate = ParagraphProjectionSpyDelegate()
        textContentStorage.delegate = previousDelegate

        textView.setWYSIWYGZeroWidthFoldingEnabled(true)
        XCTAssertTrue(textContentStorage.delegate is WYSIWYGZeroWidthTextContentStorageDelegate)

        textView.setWYSIWYGZeroWidthFoldingEnabled(false)
        XCTAssertTrue(textContentStorage.delegate === previousDelegate)
    }

    func testZeroWidthDelegateInstallsWithoutPreviousDelegate() throws {
        let textView = MarkdownSTTextView(frame: .zero)
        textView.text = "plain paragraph"
        let textContentStorage = try XCTUnwrap(textView.textContentManager as? NSTextContentStorage)
        XCTAssertNil(textContentStorage.delegate)

        textView.setWYSIWYGZeroWidthFoldingEnabled(true)
        XCTAssertTrue(textContentStorage.delegate is WYSIWYGZeroWidthTextContentStorageDelegate)

        textView.setWYSIWYGZeroWidthFoldingEnabled(false)
        XCTAssertNil(textContentStorage.delegate)
    }

    func testZeroWidthDelegateForwardsNonFoldedParagraphRequestsToPreviousDelegate() throws {
        let source = "plain paragraph"
        let textView = MarkdownSTTextView(frame: .zero)
        textView.text = source
        let textContentStorage = try XCTUnwrap(textView.textContentManager as? NSTextContentStorage)
        let forwardedParagraph = NSTextParagraph(
            attributedString: NSAttributedString(string: "previous delegate paragraph")
        )
        let previousDelegate = ParagraphProjectionSpyDelegate(paragraphToReturn: forwardedParagraph)
        textContentStorage.delegate = previousDelegate

        textView.setWYSIWYGZeroWidthFoldingEnabled(true)
        let zeroWidthDelegate = try XCTUnwrap(
            textContentStorage.delegate as? WYSIWYGZeroWidthTextContentStorageDelegate
        )
        let range = (source as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
        let paragraph = zeroWidthDelegate.textContentStorage(textContentStorage, textParagraphWith: range)

        XCTAssertEqual(previousDelegate.requestedRanges, [range])
        XCTAssertEqual(paragraph?.attributedString.string, forwardedParagraph.attributedString.string)
    }

    func testZeroWidthDelegateOwnsFoldedParagraphProjection() throws {
        let source = "A **bold** and `code` done"
        let textView = MarkdownSTTextView(frame: .zero)
        textView.font = MarkdownSyntaxHighlighter.defaultFont
        textView.text = source
        let textContentStorage = try XCTUnwrap(textView.textContentManager as? NSTextContentStorage)
        let previousDelegate = ParagraphProjectionSpyDelegate(
            paragraphToReturn: NSTextParagraph(attributedString: NSAttributedString(string: "previous"))
        )
        textContentStorage.delegate = previousDelegate

        textView.setWYSIWYGZeroWidthFoldingEnabled(true)
        XCTAssertTrue(applyProductionPresentation(
            source,
            selection: NSRange(location: 0, length: 0),
            revision: 1,
            to: textView
        ))

        let zeroWidthDelegate = try XCTUnwrap(
            textContentStorage.delegate as? WYSIWYGZeroWidthTextContentStorageDelegate
        )
        let range = (source as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
        let paragraph = try XCTUnwrap(
            zeroWidthDelegate.textContentStorage(textContentStorage, textParagraphWith: range)
        )
        let projected = paragraph.attributedString.string as NSString

        XCTAssertTrue(previousDelegate.requestedRanges.isEmpty)
        XCTAssertEqual(projected.length, (source as NSString).length)
        XCTAssertEqual(MarkdownTextView.textStorage(of: textView)?.string, source)

        let delimiters = Self.delimiters(in: source, span: "**bold**", marker: "**")
            + Self.delimiters(in: source, span: "`code`", marker: "`")
        for delimiter in delimiters {
            XCTAssertEqual(
                projected.substring(with: delimiter),
                String(repeating: "\u{200B}", count: delimiter.length)
            )
        }
    }

    func testWYSIWYGMoveLeftRightSkipsEmojiComposedCharacterAndCJKBoundaries() {
        let source = "A 😀漢 **bold** and `code` done"
        let textView = makeWYSIWYGTextView(source: source)
        XCTAssertTrue(applyProductionPresentation(
            source,
            selection: NSRange(location: 0, length: 0),
            revision: 1,
            to: textView
        ))

        let emojiRange = source.nsRange(of: "😀")
        let cjkRange = source.nsRange(of: "漢")
        textView.textSelection = NSRange(location: emojiRange.location, length: 0)

        textView.moveRight(nil)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: NSMaxRange(emojiRange), length: 0))
        assertSelectionEndpointsOnComposedCharacterBoundaries(textView.selectedRange(), in: source)

        textView.moveRight(nil)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: NSMaxRange(cjkRange), length: 0))
        assertSelectionEndpointsOnComposedCharacterBoundaries(textView.selectedRange(), in: source)

        textView.moveLeft(nil)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: cjkRange.location, length: 0))
        assertSelectionEndpointsOnComposedCharacterBoundaries(textView.selectedRange(), in: source)

        textView.moveLeft(nil)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: emojiRange.location, length: 0))
        assertSelectionEndpointsOnComposedCharacterBoundaries(textView.selectedRange(), in: source)
    }

    func testWYSIWYGShiftSelectionAcrossComposedCharactersAndFoldedInlineSpansCopiesExactMarkdown() {
        let source = "😀漢 **強** and `碼` done"
        let selectedRange = NSRange(
            location: source.nsRange(of: "😀").location,
            length: NSMaxRange(source.nsRange(of: "`碼`")) - source.nsRange(of: "😀").location
        )
        let selectedSource = source.substring(with: selectedRange)

        let forwardTextView = makeWYSIWYGTextView(source: source)
        XCTAssertTrue(applyProductionPresentation(
            source,
            selection: NSRange(location: 0, length: 0),
            revision: 1,
            to: forwardTextView
        ))
        forwardTextView.textSelection = NSRange(location: selectedRange.location, length: 0)
        extendSelection(
            in: forwardTextView,
            source: source,
            target: selectedRange,
            direction: .right
        )
        assertCopy(source: source, range: selectedRange, equals: selectedSource, in: forwardTextView)

        let reverseTextView = makeWYSIWYGTextView(source: source)
        XCTAssertTrue(applyProductionPresentation(
            source,
            selection: NSRange(location: 0, length: 0),
            revision: 1,
            to: reverseTextView
        ))
        reverseTextView.textSelection = NSRange(location: NSMaxRange(selectedRange), length: 0)
        extendSelection(
            in: reverseTextView,
            source: source,
            target: selectedRange,
            direction: .left
        )
        assertCopy(source: source, range: selectedRange, equals: selectedSource, in: reverseTextView)
    }
}

@MainActor
private extension WYSIWYGNativeInteractionGateTests {
    enum SelectionExtensionDirection {
        case left
        case right
    }

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

    func extendSelection(
        in textView: MarkdownSTTextView,
        source: String,
        target: NSRange,
        direction: SelectionExtensionDirection
    ) {
        var revision = 2
        for _ in 0 ..< (source as NSString).length {
            if textView.selectedRange() == target {
                return
            }

            switch direction {
            case .left:
                textView.moveLeftAndModifySelection(nil)
            case .right:
                textView.moveRightAndModifySelection(nil)
            }

            assertSelectionEndpointsOnComposedCharacterBoundaries(textView.selectedRange(), in: source)
            XCTAssertTrue(applyProductionPresentation(
                source,
                selection: textView.selectedRange(),
                revision: revision,
                to: textView
            ))
            revision += 1
        }

        XCTAssertEqual(textView.selectedRange(), target)
    }

    func assertSelectionEndpointsOnComposedCharacterBoundaries(
        _ selection: NSRange,
        in source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let text = source as NSString
        XCTAssertTrue(
            text.isComposedCharacterBoundary(selection.location),
            "Selection start \(selection.location) is inside a composed character",
            file: file,
            line: line
        )
        XCTAssertTrue(
            text.isComposedCharacterBoundary(NSMaxRange(selection)),
            "Selection end \(NSMaxRange(selection)) is inside a composed character",
            file: file,
            line: line
        )
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

private final class ParagraphProjectionSpyDelegate: NSObject, NSTextContentStorageDelegate {
    private let paragraphToReturn: NSTextParagraph?
    private(set) var requestedRanges: [NSRange] = []

    init(paragraphToReturn: NSTextParagraph? = nil) {
        self.paragraphToReturn = paragraphToReturn
        super.init()
    }

    func textContentStorage(
        _: NSTextContentStorage,
        textParagraphWith range: NSRange
    ) -> NSTextParagraph? {
        requestedRanges.append(range)
        return paragraphToReturn
    }
}

private extension NSString {
    func isComposedCharacterBoundary(_ offset: Int) -> Bool {
        guard offset > 0, offset < length else {
            return offset == 0 || offset == length
        }

        let previousSequence = rangeOfComposedCharacterSequence(at: offset - 1)
        if NSMaxRange(previousSequence) == offset {
            return true
        }

        let nextSequence = rangeOfComposedCharacterSequence(at: offset)
        return nextSequence.location == offset
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
