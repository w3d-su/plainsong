import AppKit
@testable import EditorKit
import STTextView
import XCTest

/// T0 evidence for `docs/table-wysiwyg-gates.md`: mechanism A (pipes projected to tab stops)
/// on one hardcoded 3×3 table with a left, a center and a right column.
@MainActor
final class WYSIWYGTableMechanismSpikeTests: XCTestCase {
    private typealias Fixture = WYSIWYGTableSpikeFixture

    func testT0ProjectionKeepsBackingStringAndEveryRawOffset() throws {
        let fixture = try Fixture.makeWindowedEditor(spikeEnabled: true)
        let textView = fixture.textView

        XCTAssertEqual(MarkdownTextView.textStorage(of: textView)?.string, Fixture.source)

        let header = try XCTUnwrap(Fixture.projectedParagraph(
            containing: Fixture.lineRange(Fixture.header),
            in: textView
        ))
        let zw = "\u{200B}"
        XCTAssertEqual(
            header.attributedString.string,
            // The row's last structural character hangs as a space: U+200B at a line end
            // reports x = 0 in TextKit, which collapsed the last cell's segment frame.
            "\t\(zw)Name\(zw)\t\(zw)Qty\(zw)\t\(zw)Notes\(zw) \n"
        )

        let delimiter = try XCTUnwrap(Fixture.projectedParagraph(
            containing: Fixture.lineRange(Fixture.delimiter),
            in: textView
        ))
        XCTAssertEqual(
            delimiter.attributedString.string,
            String(repeating: zw, count: (Fixture.delimiter as NSString).length) + "\n"
        )
        XCTAssertEqual(
            delimiter.attributedString.attribute(
                WYSIWYGTableRowPresentationMarker.collapsedRowAttribute,
                at: 0,
                effectiveRange: nil
            ) as? Bool,
            true
        )

        for line in [Fixture.header, Fixture.delimiter, Fixture.firstBody, Fixture.secondBody] {
            let paragraphRange = (Fixture.source as NSString).paragraphRange(for: Fixture.lineRange(line))
            let projected = try XCTUnwrap(Fixture.projectedParagraph(containing: paragraphRange, in: textView))
            XCTAssertEqual(projected.attributedString.length, paragraphRange.length, line)
        }

        // Paragraphs outside the table are not projected.
        XCTAssertNil(try Fixture.projectedParagraph(
            containing: (Fixture.source as NSString).range(of: "Intro line"),
            in: textView
        ))
    }

    func testT0HeaderCellsAreBoldOnlyInProjection() throws {
        let fixture = try Fixture.makeWindowedEditor(spikeEnabled: true)
        let nameRange = Fixture.range(of: "Name", inLine: Fixture.header)
        let header = try XCTUnwrap(Fixture.projectedParagraph(containing: nameRange, in: fixture.textView))
        let projectedFont = try XCTUnwrap(header.attributedString.attribute(
            .font,
            at: 2,
            effectiveRange: nil
        ) as? NSFont)
        XCTAssertTrue(projectedFont.fontDescriptor.symbolicTraits.contains(.bold))

        let storage = try XCTUnwrap(MarkdownTextView.textStorage(of: fixture.textView))
        let backingFont = storage.attribute(.font, at: nameRange.location, effectiveRange: nil) as? NSFont
        XCTAssertFalse(backingFont?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
    }

    func testT0CellContentAlignsAcrossRowsForLeftCenterAndRightColumns() throws {
        let fixture = try Fixture.makeWindowedEditor(spikeEnabled: true)
        let textView = fixture.textView
        let rows: [(line: String, cells: [String])] = [
            (Fixture.header, ["Name", "Qty", "Notes"]),
            (Fixture.firstBody, ["apple", "3", "crisp"]),
            (Fixture.secondBody, ["kiwi", "12", "tart and green"]),
        ]
        let frames = try rows.map { row in
            try row.cells.map { try Fixture.segmentFrame(of: Fixture.range(of: $0, inLine: row.line), in: textView) }
        }

        for row in frames {
            // Segment frames drive selection, caret and IME rects; every cell must have one.
            XCTAssertTrue(row.allSatisfy { $0.width > 1 }, "a cell has an empty segment frame")
            XCTAssertLessThan(row[0].maxX, row[1].minX, "columns overlap")
            XCTAssertLessThan(row[1].maxX, row[2].minX, "columns overlap")
        }
        for row in frames.dropFirst() {
            XCTAssertEqual(row[0].minX, frames[0][0].minX, accuracy: 0.5, "left column start")
            XCTAssertEqual(row[1].midX, frames[0][1].midX, accuracy: 0.5, "center column middle")
            XCTAssertEqual(row[2].maxX, frames[0][2].maxX, accuracy: 0.5, "right column end")
        }
    }

    func testT0CollapsedDelimiterRowDoesNotInflateOrDisplaceSiblingLines() throws {
        let presented = try Fixture.makeWindowedEditor(spikeEnabled: true)
        let raw = try Fixture.makeWindowedEditor(spikeEnabled: false)
        let source = Fixture.source as NSString

        let introHeight = try Fixture.lineFrame(at: 0, in: raw.textView).height
        let collapsed = WYSIWYGTablePresentationPlanner.collapsedRowHeight(for: MarkdownSyntaxHighlighter.defaultFont)
        XCTAssertLessThan(collapsed, introHeight)

        var previousMaxY = -CGFloat.infinity
        for line in [Fixture.header, Fixture.delimiter, Fixture.firstBody, Fixture.secondBody] {
            let frame = try Fixture.lineFrame(at: Fixture.lineRange(line).location, in: presented.textView)
            let expected = line == Fixture.delimiter ? collapsed : introHeight
            XCTAssertEqual(frame.height, expected, accuracy: 0.5, line)
            XCTAssertGreaterThanOrEqual(frame.minY, previousMaxY - 0.5, "rows overlap at \(line)")
            previousMaxY = frame.maxY
        }

        let outro = source.range(of: "Outro line").location
        let presentedOutro = try Fixture.lineFrame(at: outro, in: presented.textView)
        let rawOutro = try Fixture.lineFrame(at: outro, in: raw.textView)
        XCTAssertEqual(presentedOutro.height, introHeight, accuracy: 0.5)
        XCTAssertEqual(rawOutro.minY - presentedOutro.minY, introHeight - collapsed, accuracy: 0.5)
        XCTAssertEqual(
            try Fixture.lineFrame(at: 0, in: presented.textView).minY,
            try Fixture.lineFrame(at: 0, in: raw.textView).minY,
            accuracy: 0.5
        )
    }

    func testT0GutterNumbersEveryRowButTheCollapsedDelimiterWithoutOverlap() throws {
        let fixture = try Fixture.makeWindowedEditor(spikeEnabled: true)
        let textView = fixture.textView
        let visible = EditorLineNumberGutterFragments.visible(
            in: textView,
            minY: 0,
            maxY: 10000,
            limit: 100
        )
        let labels = EditorLineNumberGutterLayout.labels(
            for: visible.fragments,
            lineIndex: EditorScrollLineIndex(text: Fixture.source),
            selection: nil
        )

        // Lines: 1 intro, 2 blank, 3 header, 4 delimiter, 5-6 body, 7 blank, 8 outro.
        XCTAssertFalse(labels.map(\.number).contains(4))
        XCTAssertTrue(Set([1, 2, 3, 5, 6, 7, 8]).isSubset(of: Set(labels.map(\.number))))
        let font = MarkdownSyntaxHighlighter.defaultFont
        let minimumSpacing = (font.ascender - font.descender) * 0.9
        let baselines = labels.sorted { $0.number < $1.number }.map(\.baseline)
        for (upper, lower) in zip(baselines, baselines.dropFirst()) {
            XCTAssertGreaterThanOrEqual(lower - upper, minimumSpacing, "gutter numbers overlap")
        }
    }

    func testT0RealPointerClicksInTabGapsSnapToTheNearestCellContentEdge() throws {
        let fixture = try Fixture.makeWindowedEditor(spikeEnabled: true)
        let textView = fixture.textView
        let apple = Fixture.range(of: "apple", inLine: Fixture.firstBody)
        let three = Fixture.range(of: "3", inLine: Fixture.firstBody)
        let crisp = Fixture.range(of: "crisp", inLine: Fixture.firstBody)
        let appleFrame = try Fixture.segmentFrame(of: apple, in: textView)
        let threeFrame = try Fixture.segmentFrame(of: three, in: textView)
        let crispFrame = try Fixture.segmentFrame(of: crisp, in: textView)
        let midY = appleFrame.midY
        XCTAssertGreaterThan(threeFrame.minX - appleFrame.maxX, 8, "expected a visible gap")

        XCTAssertEqual(try Fixture.click(at: CGPoint(x: appleFrame.maxX + 2, y: midY), in: fixture), NSMaxRange(apple))
        XCTAssertEqual(try Fixture.click(at: CGPoint(x: threeFrame.minX - 2, y: midY), in: fixture), three.location)
        XCTAssertEqual(try Fixture.click(at: CGPoint(x: 1, y: midY), in: fixture), apple.location)
        XCTAssertEqual(
            try Fixture.click(at: CGPoint(x: crispFrame.maxX + 40, y: midY), in: fixture),
            NSMaxRange(crisp)
        )
        // A click on content still places the caret at the hit glyph.
        let inside = try Fixture.click(at: CGPoint(x: crispFrame.midX, y: midY), in: fixture)
        XCTAssertTrue(inside > crisp.location && inside < NSMaxRange(crisp))
        XCTAssertEqual(MarkdownTextView.textStorage(of: textView)?.string, Fixture.source)
    }

    func testT0ArrowsSkipHiddenStructureBetweenCells() throws {
        let fixture = try Fixture.makeWindowedEditor(spikeEnabled: true)
        let textView = fixture.textView
        let apple = Fixture.range(of: "apple", inLine: Fixture.firstBody)
        let three = Fixture.range(of: "3", inLine: Fixture.firstBody)

        textView.textSelection = NSRange(location: NSMaxRange(apple), length: 0)
        XCTAssertTrue(textView.applyWYSIWYGComposedCharacterMovement(delta: 1, extending: false))
        XCTAssertEqual(textView.selectedRange(), NSRange(location: three.location, length: 0))

        XCTAssertTrue(textView.applyWYSIWYGComposedCharacterMovement(delta: -1, extending: false))
        XCTAssertEqual(textView.selectedRange(), NSRange(location: NSMaxRange(apple), length: 0))
    }

    func testT0CopyAccessibilityAndUndoCarryNoProjectionCharacters() throws {
        let fixture = try Fixture.makeWindowedEditor(spikeEnabled: false)
        let textView = fixture.textView
        textView.undoManager?.removeAllActions()
        XCTAssertTrue(textView.setWYSIWYGTableT0SpikeEnabled(true))
        Fixture.ensureLayout(in: textView)
        XCTAssertEqual(textView.undoManager?.canUndo ?? false, false, "presentation registered undo")

        let tableRange = (Fixture.source as NSString).range(of: Fixture.table)
        textView.textSelection = tableRange

        let plain = Fixture.uniquePasteboard()
        XCTAssertTrue(textView.writeSelection(to: plain, types: [.string]))
        XCTAssertEqual(plain.string(forType: .string), Fixture.table)
        Fixture.assertNoProjectionCharacters(plain.string(forType: .string), "plain copy")

        let rich = Fixture.uniquePasteboard()
        XCTAssertTrue(textView.writeSelection(to: rich, types: [.rtf]))
        let rtfData = try XCTUnwrap(rich.data(forType: .rtf))
        let rtfString = try NSAttributedString(data: rtfData, options: [:], documentAttributes: nil).string
        XCTAssertEqual(rtfString, Fixture.table)
        Fixture.assertNoProjectionCharacters(rtfString, "RTF copy")

        XCTAssertEqual(textView.accessibilityValue() as? String, Fixture.source)
        Fixture.assertNoProjectionCharacters(textView.accessibilityValue() as? String, "AXValue")
        XCTAssertEqual(textView.accessibilitySelectedText(), Fixture.table)
        Fixture.assertNoProjectionCharacters(textView.accessibilitySelectedText(), "AXSelectedText")

        let kiwi = Fixture.range(of: "kiwi", inLine: Fixture.secondBody)
        textView.textSelection = NSRange(location: NSMaxRange(kiwi), length: 0)
        textView.insertText("s", replacementRange: NSRange(location: NSMaxRange(kiwi), length: 0))
        let edited = (Fixture.source as NSString).replacingCharacters(
            in: NSRange(location: NSMaxRange(kiwi), length: 0),
            with: "s"
        )
        XCTAssertEqual(MarkdownTextView.textStorage(of: textView)?.string, edited)

        let undoManager = try XCTUnwrap(textView.undoManager)
        XCTAssertTrue(undoManager.canUndo)
        undoManager.undo()
        XCTAssertEqual(MarkdownTextView.textStorage(of: textView)?.string, Fixture.source)
        XCTAssertTrue(undoManager.canRedo)
        undoManager.redo()
        XCTAssertEqual(MarkdownTextView.textStorage(of: textView)?.string, edited)
        Fixture.assertNoProjectionCharacters(MarkdownTextView.textStorage(of: textView)?.string, "backing after redo")
    }

    func testT0DisablingTheSpikeRestoresRawLayout() throws {
        let fixture = try Fixture.makeWindowedEditor(spikeEnabled: true)
        let textView = fixture.textView
        XCTAssertTrue(textView.setWYSIWYGTableT0SpikeEnabled(false))
        Fixture.ensureLayout(in: textView)

        let projected = try Fixture.projectedParagraph(containing: Fixture.lineRange(Fixture.header), in: textView)
        XCTAssertNil(projected)
        let raw = try Fixture.makeWindowedEditor(spikeEnabled: false)
        let delimiterOffset = Fixture.lineRange(Fixture.delimiter).location
        XCTAssertEqual(
            try Fixture.lineFrame(at: delimiterOffset, in: textView).height,
            try Fixture.lineFrame(at: delimiterOffset, in: raw.textView).height,
            accuracy: 0.5
        )
    }
}

final class WYSIWYGTableRowCaretSnapTests: XCTestCase {
    // "| ab    |cd |" — cell contents "ab" [2,4) and "cd" [9,11); pipes 0, 8, 12.
    private let row = NSRange(location: 0, length: 13)
    private let contents = [NSRange(location: 2, length: 2), NSRange(location: 9, length: 2)]
    private let tabs = [0, 8]

    private func snap(_ offset: Int, _ direction: WYSIWYGCaretSnap.Direction) -> Int {
        WYSIWYGTableRowCaretSnap.snap(
            offset: offset,
            rowRange: row,
            contentRanges: contents,
            tabOffsets: tabs,
            preferring: direction
        )
    }

    func testContentOffsetsAndEdgesStay() {
        for offset in [2, 3, 4, 9, 10, 11] {
            XCTAssertEqual(snap(offset, .nearest), offset)
        }
    }

    func testNearestUsesTheTabAsDividerNotOffsetDistance() {
        // Offsets up to the pipe sit left of the tab; offset distance alone would send 8 right.
        for offset in [5, 6, 7, 8] {
            XCTAssertEqual(snap(offset, .nearest), 4, "offset \(offset)")
        }
        XCTAssertEqual(snap(9, .nearest), 9)
    }

    func testDirectionalSnapsMoveAcrossTheHiddenRun() {
        XCTAssertEqual(snap(5, .forward), 9)
        XCTAssertEqual(snap(8, .backward), 4)
    }

    func testLeadingAndTrailingRunsKeepTheLineEdgesReachableByKeyboard() {
        XCTAssertEqual(snap(0, .nearest), 2)
        XCTAssertEqual(snap(1, .forward), 2)
        XCTAssertEqual(snap(1, .backward), 0)
        XCTAssertEqual(snap(0, .backward), 0)
        XCTAssertEqual(snap(12, .nearest), 11)
        XCTAssertEqual(snap(12, .forward), 13)
        XCTAssertEqual(snap(13, .backward), 11)
        XCTAssertEqual(snap(13, .forward), 13)
    }

    func testOffsetsOutsideTheRowAreUntouched() {
        XCTAssertEqual(
            WYSIWYGTableRowCaretSnap.snap(
                offset: 20,
                rowRange: row,
                contentRanges: contents,
                tabOffsets: tabs,
                preferring: .nearest
            ),
            20
        )
    }
}
