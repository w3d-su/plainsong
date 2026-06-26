import AppKit
@testable import EditorKit
import STTextView
import XCTest

private let wysiwygIMESpikeSource = "# 標題\n\n前綴 **粗體**、*斜體*、`程式` 後綴\n"

@MainActor
final class WYSIWYGIMESpikeTests: XCTestCase {
    func testZhuyinAndPinyinMarkedTextRoundTripsAtFoldBoundaries() {
        for script in CompositionScript.allCases {
            for scenario in FoldBoundaryScenario.allCases {
                assertMarkedTextRoundTrip(script: script, scenario: scenario)
            }
        }
    }

    private func assertMarkedTextRoundTrip(
        script: CompositionScript,
        scenario: FoldBoundaryScenario,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let textView = MarkdownSTTextView(frame: .zero)
        textView.setWYSIWYGZeroWidthFoldingEnabled(true)
        textView.text = wysiwygIMESpikeSource
        textView.textSelection = NSRange(location: scenario.insertionLocation, length: 0)
        XCTAssertTrue(applyProductionPresentation(
            to: textView,
            source: wysiwygIMESpikeSource,
            selection: NSRange(location: (wysiwygIMESpikeSource as NSString).length, length: 0),
            revision: 0
        ))
        assertFoldedRangesCarryProductionAttributes(
            in: textView,
            ranges: scenario.foldedRanges,
            script: script,
            scenario: scenario,
            file: file,
            line: line
        )

        for step in script.markedSteps {
            textView.setMarkedText(
                step.text,
                selectedRange: NSRange(location: step.cursorUTF16Offset, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )

            let expectedText = wysiwygIMESpikeSource.inserting(step.text, atUTF16Offset: scenario.insertionLocation)
            XCTAssertEqual(
                Self.text(in: textView),
                expectedText,
                "\(script.name) \(scenario.name)",
                file: file,
                line: line
            )
            XCTAssertTrue(textView.hasMarkedText(), "\(script.name) \(scenario.name)", file: file, line: line)
            XCTAssertEqual(
                textView.markedRange(),
                NSRange(location: scenario.insertionLocation, length: step.text.utf16.count),
                "\(script.name) \(scenario.name)",
                file: file,
                line: line
            )
            XCTAssertEqual(
                textView.selectedRange(),
                NSRange(location: scenario.insertionLocation + step.cursorUTF16Offset, length: 0),
                "\(script.name) \(scenario.name)",
                file: file,
                line: line
            )
            assertMarkedRangeDoesNotCarryFoldAttributes(
                in: textView,
                script: script,
                scenario: scenario,
                file: file,
                line: line
            )

            let skippedFoldApply = MarkdownTextView.applyHighlightedText(
                productionPresentation(
                    wysiwygIMESpikeSource,
                    selection: textView.selectedRange(),
                    revision: 1
                ),
                to: textView
            )
            XCTAssertFalse(skippedFoldApply, "Fold/reveal attributes must not apply during marked text")
            XCTAssertEqual(
                Self.text(in: textView),
                expectedText,
                "\(script.name) \(scenario.name)",
                file: file,
                line: line
            )
            XCTAssertTrue(textView.hasMarkedText(), "\(script.name) \(scenario.name)", file: file, line: line)
            assertMarkedRangeDoesNotCarryFoldAttributes(
                in: textView,
                script: script,
                scenario: scenario,
                file: file,
                line: line
            )
        }

        textView.insertText(script.committedText, replacementRange: NSRange(location: NSNotFound, length: 0))

        let committedText = wysiwygIMESpikeSource.inserting(
            script.committedText,
            atUTF16Offset: scenario.insertionLocation
        )
        XCTAssertEqual(
            Self.text(in: textView),
            committedText,
            "\(script.name) \(scenario.name)",
            file: file,
            line: line
        )
        XCTAssertFalse(textView.hasMarkedText(), "\(script.name) \(scenario.name)", file: file, line: line)
        XCTAssertEqual(
            textView.selectedRange(),
            NSRange(location: scenario.insertionLocation + script.committedText.utf16.count, length: 0),
            "\(script.name) \(scenario.name)",
            file: file,
            line: line
        )

        let didApplyFoldAttributes = MarkdownTextView.applyHighlightedText(
            productionPresentation(
                committedText,
                selection: textView.selectedRange(),
                revision: 2
            ),
            to: textView
        )

        XCTAssertTrue(didApplyFoldAttributes, "\(script.name) \(scenario.name)", file: file, line: line)
        XCTAssertEqual(
            Self.text(in: textView),
            committedText,
            "\(script.name) \(scenario.name)",
            file: file,
            line: line
        )
        XCTAssertEqual(
            textView.selectedRange(),
            NSRange(location: scenario.insertionLocation + script.committedText.utf16.count, length: 0),
            "\(script.name) \(scenario.name)",
            file: file,
            line: line
        )
    }

    private func productionPresentation(_ text: String, selection: NSRange, revision: Int) -> HighlightedText {
        let highlighted = MarkdownSyntaxHighlighter().highlight(
            text,
            fileKind: .markdown,
            visibleRange: NSRange(location: 0, length: (text as NSString).length),
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
    private func applyProductionPresentation(
        to textView: STTextView,
        source: String,
        selection: NSRange,
        revision: Int
    ) -> Bool {
        MarkdownTextView.applyHighlightedText(
            productionPresentation(source, selection: selection, revision: revision),
            to: textView
        )
    }

    private func assertFoldedRangesCarryProductionAttributes(
        in textView: STTextView,
        ranges: [NSRange],
        script: CompositionScript,
        scenario: FoldBoundaryScenario,
        file: StaticString,
        line: UInt
    ) {
        guard let textStorage = MarkdownTextView.textStorage(of: textView) else {
            XCTFail("Expected text storage for \(script.name) \(scenario.name)", file: file, line: line)
            return
        }

        for range in ranges {
            let attributes = textStorage.attributes(at: range.location, effectiveRange: nil)
            XCTAssertTrue(
                WYSIWYGInlineFoldPresentation.containsFoldedDelimiterAttributes(attributes),
                "Production fold presentation should hide \(range) for \(script.name) \(scenario.name)",
                file: file,
                line: line
            )
        }
    }

    private func assertMarkedRangeDoesNotCarryFoldAttributes(
        in textView: STTextView,
        script: CompositionScript,
        scenario: FoldBoundaryScenario,
        file: StaticString,
        line: UInt
    ) {
        let markedRange = textView.markedRange()
        guard markedRange.location != NSNotFound, markedRange.length > 0 else {
            XCTFail("Expected active marked text for \(script.name) \(scenario.name)", file: file, line: line)
            return
        }

        guard let textStorage = MarkdownTextView.textStorage(of: textView) else {
            XCTFail("Expected text storage for \(script.name) \(scenario.name)", file: file, line: line)
            return
        }

        textStorage.enumerateAttributes(in: markedRange) { attributes, _, stop in
            if WYSIWYGInlineFoldPresentation.containsFoldedDelimiterAttributes(attributes) {
                XCTFail(
                    "Fold/reveal attributes must not cover active marked text for \(script.name) \(scenario.name)",
                    file: file,
                    line: line
                )
                stop.pointee = true
            }
        }
    }

    private static func text(in textView: STTextView) -> String {
        MarkdownTextView.textStorage(of: textView)?.string ?? textView.text ?? ""
    }
}

private struct CompositionScript: CaseIterable {
    let name: String
    let markedSteps: [MarkedStep]
    let committedText: String

    static let allCases = [
        CompositionScript(
            name: "Zhuyin",
            markedSteps: [
                MarkedStep(text: "ㄊ", cursorUTF16Offset: 1),
                MarkedStep(text: "ㄊㄞ", cursorUTF16Offset: 2),
                MarkedStep(text: "ㄊㄞˊ", cursorUTF16Offset: 3),
            ],
            committedText: "臺"
        ),
        CompositionScript(
            name: "Pinyin",
            markedSteps: [
                MarkedStep(text: "t", cursorUTF16Offset: 1),
                MarkedStep(text: "ta", cursorUTF16Offset: 2),
                MarkedStep(text: "tai", cursorUTF16Offset: 3),
            ],
            committedText: "臺"
        ),
    ]
}

private struct MarkedStep {
    let text: String
    let cursorUTF16Offset: Int
}

private struct FoldBoundaryScenario: CaseIterable {
    let name: String
    let insertionLocation: Int
    let foldedRanges: [NSRange]

    static let allCases: [FoldBoundaryScenario] = {
        let source = wysiwygIMESpikeSource
        let headingMarker = (source as NSString).range(of: "# ")
        let boldSpan = (source as NSString).range(of: "**粗體**")
        let boldOpening = NSRange(location: boldSpan.location, length: 2)
        let boldClosing = NSRange(location: NSMaxRange(boldSpan) - 2, length: 2)
        let boldDelimiters = [boldOpening, boldClosing]
        let italicSpan = (source as NSString).range(of: "*斜體*")
        let italicOpening = NSRange(location: italicSpan.location, length: 1)
        let italicClosing = NSRange(location: NSMaxRange(italicSpan) - 1, length: 1)
        let italicDelimiters = [italicOpening, italicClosing]
        let inlineCodeSpan = (source as NSString).range(of: "`程式`")
        let inlineCodeOpening = NSRange(location: inlineCodeSpan.location, length: 1)
        let inlineCodeClosing = NSRange(location: NSMaxRange(inlineCodeSpan) - 1, length: 1)
        let inlineCodeDelimiters = [inlineCodeOpening, inlineCodeClosing]

        return [
            FoldBoundaryScenario(
                name: "heading after folded marker",
                insertionLocation: NSMaxRange(headingMarker),
                foldedRanges: [headingMarker]
            ),
            FoldBoundaryScenario(
                name: "bold before folded opening delimiter",
                insertionLocation: boldOpening.location,
                foldedRanges: boldDelimiters
            ),
            FoldBoundaryScenario(
                name: "bold after folded opening delimiter",
                insertionLocation: NSMaxRange(boldOpening),
                foldedRanges: boldDelimiters
            ),
            FoldBoundaryScenario(
                name: "bold before folded closing delimiter",
                insertionLocation: boldClosing.location,
                foldedRanges: boldDelimiters
            ),
            FoldBoundaryScenario(
                name: "bold after folded closing delimiter",
                insertionLocation: NSMaxRange(boldClosing),
                foldedRanges: boldDelimiters
            ),
            FoldBoundaryScenario(
                name: "italic before folded opening delimiter",
                insertionLocation: italicOpening.location,
                foldedRanges: italicDelimiters
            ),
            FoldBoundaryScenario(
                name: "italic after folded opening delimiter",
                insertionLocation: NSMaxRange(italicOpening),
                foldedRanges: italicDelimiters
            ),
            FoldBoundaryScenario(
                name: "italic before folded closing delimiter",
                insertionLocation: italicClosing.location,
                foldedRanges: italicDelimiters
            ),
            FoldBoundaryScenario(
                name: "italic after folded closing delimiter",
                insertionLocation: NSMaxRange(italicClosing),
                foldedRanges: italicDelimiters
            ),
            FoldBoundaryScenario(
                name: "inline code before folded opening delimiter",
                insertionLocation: inlineCodeOpening.location,
                foldedRanges: inlineCodeDelimiters
            ),
            FoldBoundaryScenario(
                name: "inline code after folded opening delimiter",
                insertionLocation: NSMaxRange(inlineCodeOpening),
                foldedRanges: inlineCodeDelimiters
            ),
            FoldBoundaryScenario(
                name: "inline code before folded closing delimiter",
                insertionLocation: inlineCodeClosing.location,
                foldedRanges: inlineCodeDelimiters
            ),
            FoldBoundaryScenario(
                name: "inline code after folded closing delimiter",
                insertionLocation: NSMaxRange(inlineCodeClosing),
                foldedRanges: inlineCodeDelimiters
            ),
        ]
    }()
}

private extension String {
    func inserting(_ insertion: String, atUTF16Offset offset: Int) -> String {
        let index = String.Index(utf16Offset: offset, in: self)
        return String(self[..<index]) + insertion + String(self[index...])
    }
}
