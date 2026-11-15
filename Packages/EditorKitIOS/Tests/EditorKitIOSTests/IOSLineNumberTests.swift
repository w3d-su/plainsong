@testable import EditorKitIOS
import SyntaxKit
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

    func testTrailingNewlineNumbersTheBlankLine() {
        let harness = IOSEditorHarness(text: "one\ntwo\n")
        harness.textView.frame.size = CGSize(width: 200, height: 400)
        XCTAssertEqual(preparedLabels(harness).map(\.number), [1, 2, 3])
    }

    func testWrappedParagraphDoesNotRepeatTheLineNumber() {
        let harness = IOSEditorHarness(text: String(repeating: "alpha ", count: 40))
        harness.textView.frame.size = CGSize(width: 80, height: 400)
        let numbers = preparedLabels(harness).map(\.number)
        XCTAssertEqual(numbers, [1])
    }

    func testForcedLightOverridesADarkHost() throws {
        let harness = IOSEditorHarness(text: "hello")
        harness.window.isHidden = true
        let scene = try XCTUnwrap(harness.window.windowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 200, height: 120)
        let root = UIViewController()
        root.overrideUserInterfaceStyle = .dark
        window.rootViewController = root
        window.makeKeyAndVisible()
        root.view.addSubview(harness.textView)
        harness.textView.frame = root.view.bounds
        window.layoutIfNeeded()
        harness.controller.applyInterfaceStyle(.light)
        harness.controller.theme = IOSEditorTheme.reading(appearance: .light, pointSize: 13)
        assertLight(harness)
        harness.controller.theme = IOSEditorTheme.reading(
            appearance: .light, pointSize: 18, fontName: "Menlo"
        )
        assertLight(harness)
        harness.controller.applyInterfaceStyle(.unspecified)
        window.layoutIfNeeded()
        XCTAssertEqual(harness.textView.overrideUserInterfaceStyle, .unspecified)
        XCTAssertEqual(harness.textView.traitCollection.userInterfaceStyle, .dark)
        XCTAssertEqual(
            harness.textView.lineNumberGutter.traitCollection.userInterfaceStyle,
            .dark
        )
        assertFollowsDarkHost(harness)
    }

    private func assertLight(_ harness: IOSEditorHarness) {
        XCTAssertEqual(harness.textView.traitCollection.userInterfaceStyle, .light)
        XCTAssertEqual(
            harness.textView.lineNumberGutter.traitCollection.userInterfaceStyle,
            .light
        )
        assertPinned(harness.textView.backgroundColor, to: .systemBackground)
        assertPinned(harness.textView.lineNumberGutter.backgroundColor, to: .systemBackground)
        assertPinned(harness.textView.textColor, to: .label)
        let gutter = harness.controller.theme.gutterColor(current: false)
        assertPinned(harness.controller.resolvedAppearanceColor(gutter), to: gutter)
        let source = harness.textView.textStorage.string
        let covered = NSRange(location: 0, length: source.utf16.count)
        XCTAssertTrue(IOSHighlightPresenter.apply(
            tokens: [MarkdownSyntaxToken(kind: .inlineCode, range: covered)],
            coveredRange: covered,
            expectedFragment: source,
            theme: harness.controller.theme,
            to: harness.textView
        ))
        let syntax = harness.textView.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        assertPinned(syntax, to: harness.controller.theme.color(for: .inlineCode))
    }

    private func assertFollowsDarkHost(_ harness: IOSEditorHarness) {
        let background = harness.textView.backgroundColor
        let asHost = background?.resolvedColor(with: harness.textView.traitCollection)
        let asLight = background?.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var hostWhite: CGFloat = -1
        var lightWhite: CGFloat = -1
        XCTAssertTrue(asHost?.getWhite(&hostWhite, alpha: nil) == true)
        XCTAssertTrue(asLight?.getWhite(&lightWhite, alpha: nil) == true)
        XCTAssertEqual(hostWhite, 0, accuracy: 0.02)
        XCTAssertEqual(lightWhite, 1, accuracy: 0.02)
    }

    /// A forced color stays light even when resolved with a dark trait collection.
    private func assertPinned(
        _ color: UIColor?,
        to expected: UIColor,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let light = UITraitCollection(userInterfaceStyle: .light)
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        let actual = components(of: color?.resolvedColor(with: dark))
        let wanted = components(of: expected.resolvedColor(with: light))
        for (actualValue, wantedValue) in zip(actual, wanted) {
            XCTAssertEqual(actualValue, wantedValue, accuracy: 0.02, file: file, line: line)
        }
    }

    /// Red, green, blue, and alpha; all -1 when the color has no RGB or white form.
    private func components(of color: UIColor?) -> [CGFloat] {
        var red: CGFloat = -1
        var green: CGFloat = -1
        var blue: CGFloat = -1
        var alpha: CGFloat = -1
        if color?.getRed(&red, green: &green, blue: &blue, alpha: &alpha) == true {
            return [red, green, blue, alpha]
        }
        var white: CGFloat = -1
        if color?.getWhite(&white, alpha: &alpha) == true {
            return [white, white, white, alpha]
        }
        return [red, green, blue, alpha]
    }

    private func preparedLabels(_ harness: IOSEditorHarness) -> [IOSLineNumberLabel] {
        harness.textView.layoutIfNeeded()
        if let manager = harness.textView.textLayoutManager, let content = manager.textContentManager {
            manager.ensureLayout(for: content.documentRange)
        }
        return harness.controller.lineNumberLabels()
    }
}
