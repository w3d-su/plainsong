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
        developmentPresentation: MarkdownEditorDevelopmentPresentation = .inlineFoldReveal,
        to textView: STTextView,
        coordinator: MarkdownTextViewCoordinator? = nil
    ) -> Bool {
        let presentation = productionPresentation(
            source,
            selection: selection,
            revision: revision,
            developmentPresentation: developmentPresentation
        )
        let didApply = MarkdownTextView.applyHighlightedText(presentation, to: textView)
        if didApply, let coordinator, let imageTextView = textView as? MarkdownSTTextView {
            coordinator.applyImageThumbnailPresentation(
                foldPlan: presentation.foldPlan,
                in: imageTextView,
                forceReapply: true
            )
        }
        return didApply
    }

    func productionPresentation(
        _ text: String,
        selection: NSRange,
        revision: Int,
        developmentPresentation: MarkdownEditorDevelopmentPresentation = .inlineFoldReveal
    ) -> HighlightedText {
        let highlighted = MarkdownSyntaxHighlighter().highlight(
            text,
            fileKind: .markdown,
            visibleRange: NSRange(location: 0, length: (text as NSString).length),
            developmentPresentation: developmentPresentation,
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
            textStorage.enumerateAttributes(in: range) { attributes, effectiveRange, _ in
                XCTAssertTrue(
                    WYSIWYGInlineFoldPresentation.containsFoldedDelimiterAttributes(attributes),
                    "Expected folded delimiter attributes for \(script.name) \(scenario.name) at \(effectiveRange)",
                    file: file,
                    line: line
                )
            }
        }
    }

    // swiftlint:disable:next function_parameter_count
    func assertLinkFoldAttributesReappliedAfterCommit(
        in textView: STTextView,
        committedText: String,
        presentationSelection: NSRange,
        script: ActualIMEScript,
        scenario: ActualIMEFoldBoundaryScenario,
        file: StaticString,
        line: UInt
    ) {
        let presentation = productionPresentation(
            committedText,
            selection: presentationSelection,
            revision: 101,
            developmentPresentation: scenario.developmentPresentation
        )
        let foldedLinks = presentation.foldPlan?.regions.filter { region in
            region.kind == .link && !region.isRevealed
        } ?? []
        XCTAssertEqual(
            foldedLinks.count,
            1,
            "Expected one folded link after commit for \(script.name) \(scenario.name)",
            file: file,
            line: line
        )
        assertFoldedRangesCarryProductionAttributes(
            in: textView,
            ranges: foldedLinks.flatMap(\.foldRanges),
            script: script,
            scenario: scenario,
            file: file,
            line: line
        )
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

    func assertImagePresentationSkippedDuringMarkedText(
        in textView: STTextView,
        currentText: String,
        script: ActualIMEScript,
        scenario: ActualIMEFoldBoundaryScenario
    ) {
        guard scenario.imagePresentationState != nil else {
            return
        }
        guard let imageTextView = textView as? MarkdownSTTextView else {
            XCTFail("Expected MarkdownSTTextView for \(script.name) \(scenario.name)")
            return
        }
        let imageRange = (currentText as NSString).range(of: actualIMEImageGateLiteral)
        guard imageRange.location != NSNotFound else {
            XCTFail("Expected image source for \(script.name) \(scenario.name)")
            return
        }

        do {
            WYSIWYGImageThumbnailGateSupport.ensureLayout(in: imageTextView)
            let projected = try WYSIWYGImageThumbnailGateSupport.lineFragment(
                containing: imageRange,
                in: imageTextView
            ).attributedString.string
            XCTAssertTrue(
                projected.contains(actualIMEImageGateLiteral),
                "Image source must stay raw during marked text for \(script.name) \(scenario.name)"
            )
            XCTAssertFalse(
                projected.contains("\u{FFFC}"),
                "Image presentation must be skipped during marked text for \(script.name) \(scenario.name)"
            )
        } catch {
            XCTFail(
                "Could not inspect image projection for \(script.name) \(scenario.name): \(error)"
            )
        }
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
            developmentPresentation: scenario.developmentPresentation,
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
        assertImagePresentationSkippedDuringMarkedText(
            in: textView,
            currentText: currentText,
            script: script,
            scenario: scenario
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
