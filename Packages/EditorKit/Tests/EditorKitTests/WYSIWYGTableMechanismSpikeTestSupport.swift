import AppKit
@testable import EditorKit
import STTextView
import XCTest

/// Fixture and layout probes for the table T0 spike (`docs/table-wysiwyg-gates.md` T0).
@MainActor
enum WYSIWYGTableSpikeFixture {
    nonisolated static let header = "| Name | Qty | Notes |"
    nonisolated static let delimiter = "| :--- | :---: | ---: |"
    nonisolated static let firstBody = "| apple | 3 | crisp |"
    nonisolated static let secondBody = "| kiwi | 12 | tart and green |"
    nonisolated static let table = [header, delimiter, firstBody, secondBody].joined(separator: "\n")
    nonisolated static let source = "Intro line\n\n\(table)\n\nOutro line\n"

    struct WindowedEditor {
        let window: NSWindow
        let textView: MarkdownSTTextView
    }

    static func range(of needle: String, inLine line: String) -> NSRange {
        let lineRange = (source as NSString).range(of: line)
        precondition(lineRange.location != NSNotFound)
        let local = (line as NSString).range(of: needle)
        precondition(local.location != NSNotFound)
        return NSRange(location: lineRange.location + local.location, length: local.length)
    }

    static func lineRange(_ line: String) -> NSRange {
        let range = (source as NSString).range(of: line)
        precondition(range.location != NSNotFound)
        return range
    }

    static func makeWindowedEditor(
        source: String = source,
        spikeEnabled: Bool,
        frame: NSRect = NSRect(x: 0, y: 0, width: 640, height: 360)
    ) throws -> WindowedEditor {
        let scrollView = MarkdownSTTextView.scrollableTextView(frame: frame)
        let textView = try XCTUnwrap(scrollView.documentView as? MarkdownSTTextView)
        textView.isEditable = true
        textView.isSelectable = true
        textView.isHorizontallyResizable = false
        textView.showsLineNumbers = false
        textView.font = MarkdownSyntaxHighlighter.defaultFont
        textView.text = source

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
        if spikeEnabled {
            XCTAssertTrue(textView.setWYSIWYGTableT0SpikeEnabled(true))
        }
        ensureLayout(in: textView)
        return WindowedEditor(window: window, textView: textView)
    }

    static func ensureLayout(in textView: STTextView) {
        textView.textLayoutManager.ensureLayout(for: textView.textLayoutManager.documentRange)
        textView.layoutSubtreeIfNeeded()
    }

    static func projectedParagraph(
        containing range: NSRange,
        in textView: MarkdownSTTextView
    ) throws -> NSTextParagraph? {
        let storage = try XCTUnwrap(textView.textContentManager as? NSTextContentStorage)
        let delegate = try XCTUnwrap(storage.delegate as? WYSIWYGZeroWidthTextContentStorageDelegate)
        let paragraphRange = (source as NSString).paragraphRange(for: range)
        return delegate.textContentStorage(storage, textParagraphWith: paragraphRange)
    }

    /// Union of the laid-out segment frames for `range`, in text container coordinates.
    static func segmentFrame(of range: NSRange, in textView: STTextView) throws -> CGRect {
        let textRange = try XCTUnwrap(NSTextRange(range, in: textView.textContentManager))
        var union: CGRect?
        textView.textLayoutManager
            .enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
                union = union?.union(frame) ?? frame
                return true
            }
        return try XCTUnwrap(union)
    }

    /// The typographic frame of the first line of the paragraph containing `offset`.
    static func lineFrame(at offset: Int, in textView: STTextView) throws -> CGRect {
        let location = try XCTUnwrap(textView.textContentManager.location(
            textView.textContentManager.documentRange.location,
            offsetBy: offset
        ))
        let fragment = try XCTUnwrap(textView.textLayoutManager.textLayoutFragment(for: location))
        let line = try XCTUnwrap(fragment.textLineFragments.first)
        let origin = fragment.layoutFragmentFrame.origin
        return line.typographicBounds.offsetBy(dx: origin.x, dy: origin.y)
    }

    static func click(at point: CGPoint, in fixture: WindowedEditor) throws -> Int {
        let windowPoint = fixture.textView.convert(point, to: nil)
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

    static func uniquePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PlainsongTableT0.\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    static func assertNoProjectionCharacters(
        _ string: String?,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let string else {
            XCTFail("\(label) is nil", file: file, line: line)
            return
        }
        for (scalar, name) in [(0x0009, "U+0009"), (0x200B, "U+200B"), (0xFFFC, "U+FFFC")] {
            XCTAssertFalse(
                string.unicodeScalars.contains { $0.value == scalar },
                "\(label) contains \(name)",
                file: file,
                line: line
            )
        }
    }
}
