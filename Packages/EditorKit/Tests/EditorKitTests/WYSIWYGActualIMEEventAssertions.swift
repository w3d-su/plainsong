@testable import EditorKit
import Foundation
import STTextView
import XCTest

@MainActor
extension ActualIMEEventHarness {
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

    func productionPresentation(_ text: String, selection: NSRange, revision: Int) -> HighlightedText {
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

    func assertFoldedRangesCarryProductionAttributes(
        in textView: STTextView,
        ranges: [NSRange],
        script: ActualIMEScript,
        scenario: ActualIMEFoldBoundaryScenario,
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
                "Expected folded delimiter attributes for \(script.name) \(scenario.name) at \(range)",
                file: file,
                line: line
            )
        }
    }

    func assertActiveMarkedText(
        in textView: STTextView,
        acceptableInsertedTexts: [String],
        script: ActualIMEScript,
        scenario: ActualIMEFoldBoundaryScenario,
        file: StaticString,
        line: UInt
    ) {
        XCTAssertTrue(textView.hasMarkedText(), "\(script.name) \(scenario.name)", file: file, line: line)
        let markedRange = textView.markedRange()
        XCTAssertEqual(
            markedRange.location,
            scenario.insertionLocation,
            "\(script.name) \(scenario.name)",
            file: file,
            line: line
        )
        XCTAssertTrue(
            acceptableInsertedTexts.map(\.utf16.count).contains(markedRange.length),
            "\(script.name) \(scenario.name) marked range \(markedRange)",
            file: file,
            line: line
        )

        let selectedRange = textView.selectedRange()
        XCTAssertTrue(
            selectedRange.location >= markedRange.location && NSMaxRange(selectedRange) <= NSMaxRange(markedRange),
            "\(script.name) \(scenario.name) selection \(selectedRange) escaped marked range \(markedRange)",
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
    }

    func assertFoldApplySkippedDuringMarkedText(
        in textView: STTextView,
        currentText: String,
        script: ActualIMEScript,
        scenario: ActualIMEFoldBoundaryScenario,
        file: StaticString,
        line: UInt
    ) {
        let skipped = applyProductionPresentation(
            currentText,
            selection: textView.selectedRange(),
            revision: 1,
            to: textView
        )
        XCTAssertFalse(
            skipped,
            "Fold/reveal attributes must not apply during marked text for \(script.name) \(scenario.name)",
            file: file,
            line: line
        )
        XCTAssertEqual(Self.text(in: textView), currentText, "\(script.name) \(scenario.name)", file: file, line: line)
        assertMarkedRangeDoesNotCarryFoldAttributes(
            in: textView,
            script: script,
            scenario: scenario,
            file: file,
            line: line
        )
    }

    func assertMarkedRangeDoesNotCarryFoldAttributes(
        in textView: STTextView,
        script: ActualIMEScript,
        scenario: ActualIMEFoldBoundaryScenario,
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

    static func text(in textView: STTextView) -> String {
        MarkdownTextView.textStorage(of: textView)?.string ?? textView.text ?? ""
    }
}
