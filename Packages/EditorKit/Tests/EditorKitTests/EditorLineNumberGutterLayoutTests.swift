@testable import EditorKit
import XCTest

final class EditorLineNumberGutterLayoutTests: XCTestCase {
    private typealias Layout = EditorLineNumberGutterLayout

    func testWrappedParagraphIsNumberedOnceAtItsFirstVisualLine() {
        let text = "first paragraph wraps over three visual lines\nsecond\n"
        let firstLine = line(top: 0)
        let wrapped = CGRect(x: 0, y: 0, width: 300, height: 60)
        let fragments = [
            Layout.Fragment(location: 0, firstLine: firstLine, bodyFrame: wrapped),
            Layout.Fragment(
                location: 46,
                firstLine: line(top: 60),
                bodyFrame: line(top: 60).frame,
                extraLine: line(top: 80)
            ),
        ]

        let labels = Layout.labels(for: fragments, lineIndex: EditorScrollLineIndex(text: text), selection: nil)

        XCTAssertEqual(labels.map(\.number), [1, 2, 3])
        XCTAssertEqual(labels[0].baseline, firstLine.baseline)
        XCTAssertEqual(labels[0].frame, wrapped, "the current-line band covers every wrapped line")
        XCTAssertEqual(labels.map(\.baseline), [16, 76, 96])
    }

    func testEmptyLastLineIsNumberedOnlyAfterAFinalNewline() {
        let withNewline = Layout.labels(
            for: [Layout.Fragment(location: 0, firstLine: line(top: 0), extraLine: line(top: 20))],
            lineIndex: EditorScrollLineIndex(text: "only\n"),
            selection: nil
        )
        XCTAssertEqual(withNewline.map(\.number), [1, 2])

        let withoutNewline = Layout.labels(
            for: [Layout.Fragment(location: 0, firstLine: line(top: 0))],
            lineIndex: EditorScrollLineIndex(text: "only"),
            selection: nil
        )
        XCTAssertEqual(withoutNewline.map(\.number), [1])

        // TextKit also ends a document on a lone `\r` with an extra line fragment, but
        // no source line starts there.
        let loneCarriageReturn = Layout.labels(
            for: [Layout.Fragment(location: 0, firstLine: line(top: 0), extraLine: line(top: 20))],
            lineIndex: EditorScrollLineIndex(text: "only\r"),
            selection: nil
        )
        XCTAssertEqual(loneCarriageReturn.map(\.number), [1])
    }

    func testCRLFLinesNumberLikeLF() {
        let text = "a\r\nb\r\nc\r\n"
        let fragments = [
            Layout.Fragment(location: 0, firstLine: line(top: 0)),
            Layout.Fragment(location: 3, firstLine: line(top: 20)),
            Layout.Fragment(location: 6, firstLine: line(top: 40), extraLine: line(top: 60)),
        ]

        let labels = Layout.labels(for: fragments, lineIndex: EditorScrollLineIndex(text: text), selection: nil)

        XCTAssertEqual(labels.map(\.number), [1, 2, 3, 4])
    }

    func testParagraphsStartedWithoutANewlineContinueTheirSourceLine() {
        // TextKit starts paragraphs after `\r` and U+2029; scroll sync and the preview
        // count only `\n`, so those paragraphs carry no number of their own.
        let text = "a\rb\u{2029}c\nd"
        let fragments = [0, 2, 4, 6].enumerated().map { index, location in
            Layout.Fragment(location: location, firstLine: line(top: CGFloat(index) * 20))
        }

        let labels = Layout.labels(for: fragments, lineIndex: EditorScrollLineIndex(text: text), selection: nil)

        XCTAssertEqual(labels.map(\.number), [1, 2])
        XCTAssertEqual(labels.map(\.baseline), [16, 76])
    }

    func testFragmentsWithoutLaidOutLinesDrawNothing() {
        let labels = Layout.labels(
            for: [Layout.Fragment(location: 0), Layout.Fragment(location: 2, firstLine: line(top: 20))],
            lineIndex: EditorScrollLineIndex(text: "a\nb"),
            selection: nil
        )

        XCTAssertEqual(labels.map(\.number), [2])
    }

    func testEmptyDocumentNumbersItsOnlyLine() {
        let labels = Layout.labels(
            for: [Layout.Fragment(location: 0, firstLine: line(top: 0))],
            lineIndex: EditorScrollLineIndex(text: ""),
            selection: NSRange(location: 0, length: 0)
        )

        XCTAssertEqual(labels.map(\.number), [1])
        XCTAssertEqual(labels.map(\.isCurrent), [true])
    }

    func testCurrentLinesFollowTheSelection() {
        let index = EditorScrollLineIndex(text: "one\ntwo\nthree\nfour\n")

        XCTAssertEqual(Layout.currentLineRange(for: NSRange(location: 5, length: 0), in: index), 2 ... 2)
        XCTAssertEqual(Layout.currentLineRange(for: NSRange(location: 4, length: 0), in: index), 2 ... 2)
        XCTAssertEqual(Layout.currentLineRange(for: NSRange(location: 3, length: 0), in: index), 1 ... 1)
        XCTAssertEqual(Layout.currentLineRange(for: NSRange(location: 1, length: 9), in: index), 1 ... 3)
        // Selecting through a line break does not touch the following line.
        XCTAssertEqual(Layout.currentLineRange(for: NSRange(location: 4, length: 4), in: index), 2 ... 2)
        XCTAssertEqual(Layout.currentLineRange(for: NSRange(location: 19, length: 0), in: index), 5 ... 5)
        XCTAssertNil(Layout.currentLineRange(for: NSRange(location: NSNotFound, length: 0), in: index))
        XCTAssertNil(Layout.currentLineRange(for: nil, in: index))

        let fragments = (0 ..< 4).map { lineNumber in
            Layout.Fragment(
                location: index.utf16Offset(forOneBasedLine: lineNumber + 1),
                firstLine: line(top: CGFloat(lineNumber) * 20)
            )
        }
        let labels = Layout.labels(for: fragments, lineIndex: index, selection: NSRange(location: 6, length: 3))
        XCTAssertEqual(labels.filter(\.isCurrent).map(\.number), [2, 3])
    }

    func testLineNumberStartingAtAnOffsetRequiresAnExactLineStart() {
        let index = EditorScrollLineIndex(text: "ab\ncd\n")

        XCTAssertEqual(Layout.lineNumber(startingAt: 0, in: index), 1)
        XCTAssertNil(Layout.lineNumber(startingAt: 1, in: index))
        XCTAssertEqual(Layout.lineNumber(startingAt: 3, in: index), 2)
        XCTAssertEqual(Layout.lineNumber(startingAt: 6, in: index), 3)
        XCTAssertNil(Layout.lineNumber(startingAt: 7, in: index))
        XCTAssertNil(Layout.lineNumber(startingAt: -1, in: index))
    }

    func testDigitsGrowAtOnceAndShrinkOnlyWellBelowTheNarrowerLimit() {
        typealias Digits = EditorLineNumberGutterDigits
        XCTAssertEqual(Digits.next(forLineCount: 1, current: nil), 3)
        XCTAssertEqual(Digits.next(forLineCount: 999, current: 3), 3)
        XCTAssertEqual(Digits.next(forLineCount: 1000, current: 3), 4)
        // Deleting back below 1000 keeps the width until the count is clearly smaller.
        XCTAssertEqual(Digits.next(forLineCount: 999, current: 4), 4)
        XCTAssertEqual(Digits.next(forLineCount: 900, current: 4), 4)
        XCTAssertEqual(Digits.next(forLineCount: 899, current: 4), 3)
        XCTAssertEqual(Digits.next(forLineCount: 33141, current: 4), 5)
        XCTAssertEqual(Digits.next(forLineCount: 9000, current: 5), 5)
        // Opening a short document after a long one shrinks straight to its width.
        XCTAssertEqual(Digits.next(forLineCount: 120, current: 5), 3)
        XCTAssertEqual(Digits.shrinkThreshold(below: 4), 900)
        XCTAssertEqual(Digits.shrinkThreshold(below: 6), 90000)
        XCTAssertEqual(EditorLineNumberGutterView.thickness(digits: 3, digitWidth: 7.8), 34)
    }

    private func line(top: CGFloat) -> Layout.Line {
        Layout.Line(frame: CGRect(x: 0, y: top, width: 300, height: 20), baseline: top + 16)
    }
}
