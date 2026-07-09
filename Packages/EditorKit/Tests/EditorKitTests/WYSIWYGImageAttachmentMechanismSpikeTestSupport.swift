import AppKit
@testable import EditorKit
import STTextView
import XCTest

@MainActor
extension WYSIWYGImageAttachmentMechanismSpikeTests {
    struct WindowedEditor {
        let window: NSWindow
        let textView: MarkdownSTTextView
    }

    static var imageRange: NSRange {
        let range = (source as NSString).range(of: WYSIWYGImageAttachmentI0Spike.source)
        precondition(range.location != NSNotFound)
        return range
    }

    func makeSpikeTextView() -> MarkdownSTTextView {
        let textView = MarkdownSTTextView(frame: .zero)
        textView.font = MarkdownSyntaxHighlighter.defaultFont
        textView.text = Self.source
        XCTAssertTrue(textView.setWYSIWYGImageAttachmentI0SpikeEnabled(true))
        return textView
    }

    func makeWindowedEditor(
        source: String? = nil,
        frame: NSRect = NSRect(x: 0, y: 0, width: 640, height: 360),
        spikeEnabled: Bool
    ) throws -> WindowedEditor {
        let source = source ?? Self.source
        let scrollView = MarkdownSTTextView.scrollableTextView(frame: frame)
        let textView = try XCTUnwrap(scrollView.documentView as? MarkdownSTTextView)
        textView.isEditable = true
        textView.isSelectable = true
        textView.isHorizontallyResizable = false
        textView.showsLineNumbers = false
        textView.font = MarkdownSyntaxHighlighter.defaultFont
        textView.text = source
        if spikeEnabled {
            XCTAssertTrue(textView.setWYSIWYGImageAttachmentI0SpikeEnabled(true))
        }

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        textView.layoutSubtreeIfNeeded()
        ensureLayout(in: textView)
        return WindowedEditor(window: window, textView: textView)
    }

    @discardableResult
    func assertLiveAttachment(
        in textView: STTextView,
        imageRange: NSRange,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> NSTextLineFragment {
        ensureLayout(in: textView)
        let projectedLine = try lineFragment(containing: imageRange, in: textView)
        let projectedLineContents = projectedLine.attributedString.attributedSubstring(
            from: projectedLine.characterRange
        )
        XCTAssertEqual(
            projectedLineContents.string.unicodeScalars.filter { $0.value == 0xFFFC }.count,
            1,
            "Expected one live projected attachment character",
            file: file,
            line: line
        )
        let objectRange = (projectedLineContents.string as NSString).range(of: "\u{FFFC}")
        XCTAssertNotEqual(objectRange.location, NSNotFound, file: file, line: line)
        if objectRange.location != NSNotFound {
            let attachment = projectedLineContents.attribute(
                .attachment,
                at: objectRange.location,
                effectiveRange: nil
            ) as? NSTextAttachment
            XCTAssertNotNil(attachment, file: file, line: line)
            if let attachment {
                XCTAssertEqual(
                    attachment.bounds.size,
                    WYSIWYGImageAttachmentI0Spike.attachmentSize,
                    file: file,
                    line: line
                )
                XCTAssertEqual(
                    attachment.image?.size,
                    WYSIWYGImageAttachmentI0Spike.attachmentSize,
                    file: file,
                    line: line
                )
            }
        }
        return projectedLine
    }

    func clickAttachment(in fixture: WindowedEditor, imageRange: NSRange) throws -> Int {
        let projectedLine = try assertLiveAttachment(
            in: fixture.textView,
            imageRange: imageRange
        )
        let attachmentRect = try lineFragmentFrame(containing: imageRange, in: fixture.textView)
        XCTAssertEqual(
            attachmentRect.width,
            WYSIWYGImageAttachmentI0Spike.attachmentSize.width,
            accuracy: 1
        )
        XCTAssertEqual(
            attachmentRect.height,
            projectedLine.typographicBounds.height,
            accuracy: 0.5
        )
        let windowPoint = fixture.textView.convert(
            CGPoint(x: attachmentRect.midX, y: attachmentRect.midY),
            to: nil
        )
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: fixture.window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))

        fixture.textView.mouseDown(with: event)
        return fixture.textView.selectedRange().location
    }

    func projectedImageParagraph(in textView: MarkdownSTTextView) throws -> (NSTextParagraph, NSRange) {
        let textContentStorage = try XCTUnwrap(textView.textContentManager as? NSTextContentStorage)
        let delegate = try XCTUnwrap(
            textContentStorage.delegate as? WYSIWYGZeroWidthTextContentStorageDelegate
        )
        let paragraphRange = (Self.source as NSString).paragraphRange(for: Self.imageRange)
        let paragraph = try XCTUnwrap(
            delegate.textContentStorage(textContentStorage, textParagraphWith: paragraphRange)
        )
        return (paragraph, paragraphRange)
    }

    func ensureLayout(in textView: STTextView) {
        textView.textLayoutManager.ensureLayout(for: textView.textLayoutManager.documentRange)
        textView.layoutSubtreeIfNeeded()
    }

    func lineFragmentFrame(containing range: NSRange, in textView: STTextView) throws -> CGRect {
        try lineFragment(containing: range, in: textView).typographicBounds.offsetBy(
            dx: layoutFragment(containing: range, in: textView).layoutFragmentFrame.minX,
            dy: layoutFragment(containing: range, in: textView).layoutFragmentFrame.minY
        )
    }

    func lineFragment(containing range: NSRange, in textView: STTextView) throws -> NSTextLineFragment {
        let fragment = try layoutFragment(containing: range, in: textView)
        let elementRange = NSRange(fragment.rangeInElement, in: textView.textContentManager)
        return try XCTUnwrap(fragment.textLineFragments.first { lineFragment in
            let lineRange = NSRange(
                location: elementRange.location + lineFragment.characterRange.location,
                length: lineFragment.characterRange.length
            )
            return NSLocationInRange(range.location, lineRange)
        })
    }

    func layoutFragment(containing range: NSRange, in textView: STTextView) throws -> NSTextLayoutFragment {
        ensureLayout(in: textView)
        let textRange = try XCTUnwrap(NSTextRange(range, in: textView.textContentManager))
        return try XCTUnwrap(textView.textLayoutManager.textLayoutFragment(for: textRange.location))
    }

    func uniquePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("PlainsongImageAttachmentI0Spike.\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        return pasteboard
    }
}
