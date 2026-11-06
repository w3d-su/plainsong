import AppKit
@testable import EditorKit
import STTextView
import XCTest

/// A folded closing delimiter at the end of a line projects to U+200B, which TextKit lays out
/// at x = 0 there. The projection hangs a near-zero-width space at the line end instead
/// (`docs/decisions/2026-11-06-wysiwyg-line-end-fold-hanging-space.md`).
@MainActor
final class WYSIWYGLineEndFoldGeometryTests: XCTestCase {
    private struct Case {
        let name: String
        let line: String
        let content: String
        /// Delimiter ranges inside `line`.
        let folded: [NSRange]
    }

    private static let cases: [Case] = [
        Case(
            name: "bold",
            line: "A **bold**",
            content: "bold",
            folded: [NSRange(location: 2, length: 2), NSRange(location: 8, length: 2)]
        ),
        Case(
            name: "code",
            line: "A `code`",
            content: "code",
            folded: [NSRange(location: 2, length: 1), NSRange(location: 7, length: 1)]
        ),
        Case(
            name: "link",
            line: "A [text](https://example.com)",
            content: "text",
            folded: [NSRange(location: 2, length: 1), NSRange(location: 7, length: 22)]
        ),
    ]

    private static let terminators: [(name: String, value: String)] = [
        ("LF", "\nnext line\n"),
        ("CRLF", "\r\nnext line\r\n"),
        ("end of document", ""),
    ]

    func testLineEndFoldedContentHasNonEmptySegmentFrameAndCaretAtContentEnd() throws {
        for testCase in Self.cases {
            for terminator in Self.terminators {
                let label = "\(testCase.name), \(terminator.name)"
                let source = testCase.line + terminator.value
                let textView = try makeTextView(source: source, folded: testCase.folded)
                let content = (testCase.line as NSString).range(of: testCase.content)
                let lineEnd = (testCase.line as NSString).length

                let contentFrame = try segmentFrame(of: content, in: textView)
                let unfoldedPrefix = try segmentFrame(
                    of: NSRange(location: 0, length: 2),
                    in: textView
                )
                XCTAssertGreaterThan(
                    contentFrame.width,
                    unfoldedPrefix.width,
                    "\(label): content segment frame is empty or collapsed: \(contentFrame)"
                )
                XCTAssertEqual(
                    contentFrame.minX,
                    unfoldedPrefix.maxX,
                    accuracy: 0.5,
                    "\(label): content starts after the visible prefix"
                )

                try assertNothingPastContentEnd(
                    contentFrame: contentFrame,
                    hiddenTail: NSRange(location: NSMaxRange(content), length: lineEnd - NSMaxRange(content)),
                    in: textView,
                    label
                )
            }
        }
    }

    /// The cancelling kern is measured from the run's own font, so a proportional face and a
    /// zoomed size leave no width either (the checklist rejected kern/tiny-font hiding as
    /// fragile across fonts and zoom, §A.4).
    func testHangingSpaceStaysWidthlessForProportionalAndZoomedFonts() throws {
        let fonts = [
            NSFont.systemFont(ofSize: 13),
            NSFont.systemFont(ofSize: 31),
            NSFont.monospacedSystemFont(ofSize: 27, weight: .regular),
        ]
        let testCase = Self.cases[0]
        for font in fonts {
            let label = "\(font.fontName) \(font.pointSize)"
            let textView = try makeTextView(
                source: testCase.line + "\nnext line\n",
                folded: testCase.folded,
                font: font
            )
            let content = (testCase.line as NSString).range(of: testCase.content)
            let contentFrame = try segmentFrame(of: content, in: textView)
            XCTAssertGreaterThan(contentFrame.width, 0, label)
            try assertNothingPastContentEnd(
                contentFrame: contentFrame,
                hiddenTail: NSRange(
                    location: NSMaxRange(content),
                    length: (testCase.line as NSString).length - NSMaxRange(content)
                ),
                in: textView,
                label
            )
        }
    }

    func testLineEndProjectionKeepsLengthAndRawSourceAndLeavesInteriorFoldsZeroWidth() throws {
        let source = "A **bold** and `code`\nnext line\n"
        let folded = [
            NSRange(location: 2, length: 2),
            NSRange(location: 8, length: 2),
            NSRange(location: 15, length: 1),
            NSRange(location: 20, length: 1),
        ]
        let textView = try makeTextView(source: source, folded: folded)
        let storage = try XCTUnwrap(textView.textContentManager as? NSTextContentStorage)
        let delegate = try XCTUnwrap(storage.delegate as? WYSIWYGZeroWidthTextContentStorageDelegate)
        let paragraphRange = (source as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
        let paragraph = try XCTUnwrap(
            delegate.textContentStorage(storage, textParagraphWith: paragraphRange)
        ).attributedString

        XCTAssertEqual(paragraph.length, paragraphRange.length)
        let units = Array(paragraph.string.utf16)
        for offset in [2, 3, 8, 9, 15] {
            XCTAssertEqual(units[offset], 0x200B, "interior fold at \(offset) stays U+200B")
        }
        XCTAssertEqual(units[20], 0x0020, "the line-end fold hangs a space")
        XCTAssertLessThan(try XCTUnwrap(paragraph.attribute(.kern, at: 20, effectiveRange: nil) as? CGFloat), 0)
        XCTAssertEqual(
            (paragraph.attribute(.font, at: 20, effectiveRange: nil) as? NSFont)?.pointSize,
            WYSIWYGLineEndHangingSpace.fontSize
        )
        XCTAssertNil(paragraph.attribute(.kern, at: 15, effectiveRange: nil))
        XCTAssertEqual(
            (paragraph.attribute(.font, at: 15, effectiveRange: nil) as? NSFont)?.pointSize,
            MarkdownSyntaxHighlighter.defaultFont.pointSize
        )
        XCTAssertEqual(units[21], 0x000A)

        XCTAssertEqual(textView.text, source, "the backing string never changes")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PlainsongLineEndFold.\(UUID().uuidString)"))
        pasteboard.clearContents()
        textView.textSelection = NSRange(location: 0, length: 21)
        XCTAssertTrue(textView.writeSelection(to: pasteboard, types: [.string]))
        XCTAssertEqual(pasteboard.string(forType: .string), "A **bold** and `code`")
        XCTAssertEqual(textView.accessibilityValue() as? String, source)
    }

    func testRawZeroWidthSpaceAtLineEndIsNotProjected() throws {
        let source = "A **bold**\u{200B}\nnext\n"
        let textView = try makeTextView(
            source: source,
            folded: [NSRange(location: 2, length: 2), NSRange(location: 8, length: 2)]
        )
        let storage = try XCTUnwrap(textView.textContentManager as? NSTextContentStorage)
        let delegate = try XCTUnwrap(storage.delegate as? WYSIWYGZeroWidthTextContentStorageDelegate)
        let paragraphRange = (source as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
        let paragraph = try XCTUnwrap(
            delegate.textContentStorage(storage, textParagraphWith: paragraphRange)
        ).attributedString
        let units = Array(paragraph.string.utf16)
        XCTAssertEqual(Array(units[8 ... 10]), [0x200B, 0x200B, 0x200B], "user text is never rewritten")
    }

    func testImageThatEndsItsLineKeepsAttachmentFrameAndCaretAfterIt() async throws {
        let fixture = try WYSIWYGImageThumbnailGateSupport.makeWindowedEditor()
        let imageRange = WYSIWYGImageThumbnailGateSupport.imageRange
        let marker = try await WYSIWYGImageThumbnailGateSupport.waitForMarker(
            in: fixture.textView,
            range: imageRange,
            matching: { if case .ready = $0.visualState { true } else { false } }
        )
        let textView = fixture.textView
        textView.textLayoutManager.ensureLayout(for: textView.textLayoutManager.documentRange)

        let attachmentFrame = try segmentFrame(
            of: NSRange(location: imageRange.location, length: 1),
            in: textView
        )
        XCTAssertEqual(attachmentFrame.width, marker.canvasSize.width, accuracy: 0.5)
        XCTAssertEqual(
            try segmentFrame(of: imageRange, in: textView).maxX,
            attachmentFrame.maxX,
            accuracy: 0.05
        )
        for offset in imageRange.location + 1 ... NSMaxRange(imageRange) {
            XCTAssertEqual(
                try caretX(at: offset, in: textView),
                attachmentFrame.maxX,
                accuracy: 0.5,
                "caret x at offset \(offset)"
            )
        }
    }
}

// MARK: - Support

private extension WYSIWYGLineEndFoldGeometryTests {
    /// Every caret from the content end to the line end (the hidden closing delimiter) rests
    /// at the visible content end, a selection over the delimiter or the whole line paints
    /// nothing past it, and the line is no wider than its visible text.
    func assertNothingPastContentEnd(
        contentFrame: CGRect,
        hiddenTail: NSRange,
        in textView: MarkdownSTTextView,
        _ label: String
    ) throws {
        for offset in hiddenTail.location ... NSMaxRange(hiddenTail) {
            XCTAssertEqual(
                try caretX(at: offset, in: textView),
                contentFrame.maxX,
                accuracy: 0.5,
                "\(label): caret x at offset \(offset)"
            )
        }
        for range in [hiddenTail, NSRange(location: 0, length: NSMaxRange(hiddenTail))] {
            XCTAssertEqual(
                try segmentFrame(of: range, in: textView).maxX,
                contentFrame.maxX,
                accuracy: 0.05,
                "\(label): segment frame of \(range) ends at the content end"
            )
        }
        let lineStart = try caretX(at: 0, in: textView)
        XCTAssertEqual(
            try firstLineFragment(in: textView).typographicBounds.width,
            contentFrame.maxX - lineStart,
            accuracy: 0.5,
            "\(label): the hanging space adds no width to the line"
        )
    }

    func makeTextView(
        source: String,
        folded: [NSRange],
        font: NSFont = MarkdownSyntaxHighlighter.defaultFont
    ) throws -> MarkdownSTTextView {
        let scrollView = MarkdownSTTextView.scrollableTextView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 360)
        )
        let textView = try XCTUnwrap(scrollView.documentView as? MarkdownSTTextView)
        textView.showsLineNumbers = false
        textView.font = font
        textView.text = source
        XCTAssertTrue(textView.setWYSIWYGZeroWidthFoldingEnabled(true))
        let textStorage = try XCTUnwrap(MarkdownTextView.textStorage(of: textView))
        for range in folded {
            textStorage.addAttribute(
                WYSIWYGInlineFoldPresentation.foldedDelimiterAttribute,
                value: true,
                range: range
            )
        }
        textView.textLayoutManager.ensureLayout(for: textView.textLayoutManager.documentRange)
        return textView
    }

    func segmentFrame(of range: NSRange, in textView: STTextView) throws -> CGRect {
        let textRange = try XCTUnwrap(NSTextRange(range, in: textView.textContentManager))
        var union: CGRect?
        textView.textLayoutManager
            .enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
                union = union?.union(frame) ?? frame
                return true
            }
        return try XCTUnwrap(union)
    }

    func caretX(at offset: Int, in textView: STTextView) throws -> CGFloat {
        let textRange = try XCTUnwrap(
            NSTextRange(NSRange(location: offset, length: 0), in: textView.textContentManager)
        )
        var caret: CGFloat?
        textView.textLayoutManager
            .enumerateTextSegments(in: textRange, type: .selection, options: []) { _, frame, _, _ in
                caret = frame.minX
                return false
            }
        return try XCTUnwrap(caret)
    }

    func firstLineFragment(in textView: STTextView) throws -> NSTextLineFragment {
        let layoutManager = textView.textLayoutManager
        let fragment = try XCTUnwrap(layoutManager.textLayoutFragment(for: layoutManager.documentRange.location))
        return try XCTUnwrap(fragment.textLineFragments.first)
    }
}
