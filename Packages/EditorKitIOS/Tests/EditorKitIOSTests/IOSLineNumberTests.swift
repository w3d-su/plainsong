@testable import EditorKitIOS
import UIKit
import XCTest

final class IOSLineNumberIndexTests: XCTestCase {
    func testNewlineIndexMatchesPreviewLines() {
        let index = IOSSourceLineIndex(text: "a\nb\n")
        XCTAssertEqual(index.lineCount, 3)
        XCTAssertEqual(index.oneBasedLine(containingUTF16Offset: 0), 1)
        XCTAssertEqual(index.utf16Offset(forOneBasedLine: 2), 2)
        XCTAssertEqual(index.oneBasedLine(containingUTF16Offset: 3), 2)
        XCTAssertEqual(index.oneBasedLine(containingUTF16Offset: 4), 3)
        XCTAssertEqual(index.utf16Offset(forOneBasedLine: 9), 4)
    }

    func testIncrementalReplacementKeepsLaterLines() {
        var index = IOSSourceLineIndex(text: "a\nb\nc")
        XCTAssertTrue(index.replaceCharacters(in: NSRange(location: 0, length: 1), with: "aa"))
        XCTAssertEqual(index.textUTF16Count, 6)
        XCTAssertEqual(index.utf16Offset(forOneBasedLine: 2), 3)
        XCTAssertEqual(index.oneBasedLine(containingUTF16Offset: 5), 3)
    }

    func testDigitWidthGrowsImmediatelyAndShrinksLate() {
        XCTAssertEqual(IOSLineNumberDigits.next(forLineCount: 999, current: 3), 3)
        XCTAssertEqual(IOSLineNumberDigits.next(forLineCount: 1000, current: 3), 4)
        XCTAssertEqual(IOSLineNumberDigits.next(forLineCount: 900, current: 4), 4)
        XCTAssertEqual(IOSLineNumberDigits.next(forLineCount: 899, current: 4), 3)
    }
}

@MainActor
final class IOSLineNumberGutterTests: XCTestCase {
    func testVisibleSourceLinesAreNumberedOnce() {
        let harness = IOSEditorHarness(text: "one\ntwo\nthree")
        harness.textView.frame.size.width = 80
        let labels = preparedLabels(harness)
        XCTAssertEqual(labels.map(\.number), [1, 2, 3])
        XCTAssertLessThan(labels[0].baseline, labels[1].baseline)
        XCTAssertLessThan(labels[1].baseline, labels[2].baseline)
        XCTAssertTrue(labels[0].isCurrent)
        XCTAssertFalse(labels[1].isCurrent)
    }

    func testSelectionMarksOnlyTheTouchedLines() {
        let harness = IOSEditorHarness(text: "one\ntwo\nthree")
        harness.placeCaret(at: iosUTF16("one\n"))
        let labels = preparedLabels(harness)
        XCTAssertEqual(labels.first { $0.isCurrent }?.number, 2)
        XCTAssertEqual(labels.filter(\.isCurrent).map(\.number), [2])
    }

    func testLineNumbersDoNotChangeSourceOrSelection() {
        let harness = IOSEditorHarness(text: "alpha\nbeta")
        harness.placeCaret(at: 3)
        let text = harness.textView.text
        let selection = harness.textView.selectedRange
        harness.controller.showsLineNumbers = false
        XCTAssertEqual(harness.textView.text, text)
        XCTAssertEqual(harness.textView.selectedRange, selection)
        XCTAssertTrue(harness.controller.lineNumberLabels().isEmpty)
        XCTAssertEqual(
            harness.textView.textContainerInset.left,
            harness.textView.baseTextContainerInset.left
        )
        harness.controller.showsLineNumbers = true
        XCTAssertEqual(harness.textView.text, text)
        XCTAssertEqual(harness.textView.selectedRange, selection)
        XCTAssertFalse(preparedLabels(harness).isEmpty)
    }

    func testScrollToALaterLineMovesTheViewport() {
        let lines = (1 ... 80).map { "line \($0)" }.joined(separator: "\n")
        let harness = IOSEditorHarness(text: lines)
        harness.textView.frame.size.height = 140
        harness.textView.layoutIfNeeded()
        harness.controller.scrollToSourceLine(40)
        let visible = harness.controller.topVisibleSourceLine()
        XCTAssertGreaterThan(harness.textView.contentOffset.y, 10)
        XCTAssertGreaterThanOrEqual(visible, 30)
        XCTAssertLessThanOrEqual(visible, 50)
    }

    func testGraphiteUsesDifferentSyntaxColors() {
        let light = UITraitCollection(userInterfaceStyle: .light)
        let plainsong = IOSEditorTheme.reading(appearance: .light, pointSize: 13, palette: .plainsong)
        let graphite = IOSEditorTheme.reading(appearance: .light, pointSize: 13, palette: .graphite)
        XCTAssertEqual(plainsong.palette, .plainsong)
        XCTAssertEqual(graphite.palette, .graphite)
        let plainCode = plainsong.color(for: .inlineCode).resolvedColor(with: light)
        let graphiteCode = graphite.color(for: .inlineCode).resolvedColor(with: light)
        XCTAssertFalse(plainCode.isEqual(graphiteCode))
        let plainFrontmatter = plainsong.color(for: .frontmatter).resolvedColor(with: light)
        let graphiteFrontmatter = graphite.color(for: .frontmatter).resolvedColor(with: light)
        XCTAssertFalse(plainFrontmatter.isEqual(graphiteFrontmatter))
    }

    func testNamedFontFallsBackAndKeepsTheRequestedSize() {
        let menlo = IOSEditorFont.font(named: "Menlo", size: 18)
        XCTAssertEqual(menlo.pointSize, 18)
        if IOSEditorFont.availableTitles().contains("Menlo") {
            XCTAssertTrue(menlo.familyName == "Menlo" || menlo.fontName.hasPrefix("Menlo"))
        }
        let missing = IOSEditorFont.font(named: "NotARealFont", size: 15)
        XCTAssertEqual(missing.pointSize, 15)
        XCTAssertEqual(IOSEditorFont.resolved("NotARealFont"), IOSEditorFont.system)
        let theme = IOSEditorTheme.reading(
            appearance: .dark, pointSize: 16, fontName: "Menlo", palette: .graphite
        )
        XCTAssertEqual(theme.baseFont.pointSize, 16)
        XCTAssertEqual(theme.palette, .graphite)
        XCTAssertEqual(theme.background, .black)
    }

    private func preparedLabels(_ harness: IOSEditorHarness) -> [IOSLineNumberLabel] {
        harness.textView.layoutIfNeeded()
        if let manager = harness.textView.textLayoutManager, let content = manager.textContentManager {
            manager.ensureLayout(for: content.documentRange)
        }
        return harness.controller.lineNumberLabels()
    }
}
