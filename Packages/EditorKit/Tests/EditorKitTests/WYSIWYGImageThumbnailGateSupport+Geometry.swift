import AppKit
@testable import EditorKit
import MarkdownCore
import STTextView
import XCTest

@MainActor
extension WYSIWYGImageThumbnailGateSupport {
    static func clickAttachment(in fixture: WindowedEditor, imageRange: NSRange) throws -> Int {
        _ = try assertLiveAttachment(in: fixture.textView, imageRange: imageRange)
        let attachmentRect = try lineFragmentFrame(containing: imageRange, in: fixture.textView)
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

    static func pointerClick(
        on characterRange: NSRange,
        in fixture: WindowedEditor,
        shift: Bool = false,
        fraction: CGFloat = 0.5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Int {
        // Projected image attachments often report a zero-width `firstRect` for interior
        // UTF-16 offsets; fall back to the live line-fragment frame that owns the span.
        let screenRect = fixture.textView.firstRect(forCharacterRange: characterRange, actualRange: nil)
        let windowPoint: CGPoint
        if screenRect.width > 0, screenRect.height > 0 {
            let screenPoint = CGPoint(
                x: screenRect.minX + screenRect.width * fraction,
                y: screenRect.midY
            )
            windowPoint = fixture.window.convertPoint(fromScreen: screenPoint)
        } else {
            let fragmentFrame = try lineFragmentFrame(containing: characterRange, in: fixture.textView)
            XCTAssertGreaterThan(fragmentFrame.width, 0, file: file, line: line)
            XCTAssertGreaterThan(fragmentFrame.height, 0, file: file, line: line)
            let localPoint = CGPoint(
                x: fragmentFrame.minX + fragmentFrame.width * fraction,
                y: fragmentFrame.midY
            )
            windowPoint = fixture.textView.convert(localPoint, to: nil)
        }
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: shift ? .shift : [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: fixture.window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ), file: file, line: line)

        fixture.textView.mouseDown(with: event)
        return fixture.textView.selectedRange().location
    }

    static func projectedImageParagraph(
        in textView: MarkdownSTTextView,
        imageRange: NSRange
    ) throws -> (NSTextParagraph, NSRange) {
        let textContentStorage = try XCTUnwrap(textView.textContentManager as? NSTextContentStorage)
        let delegate = try XCTUnwrap(
            textContentStorage.delegate as? WYSIWYGZeroWidthTextContentStorageDelegate
        )
        let paragraphRange = (textContentStorage.textStorage?.string as NSString?)?
            .paragraphRange(for: imageRange) ?? imageRange
        let paragraph = try XCTUnwrap(
            delegate.textContentStorage(textContentStorage, textParagraphWith: paragraphRange)
        )
        return (paragraph, paragraphRange)
    }

    static func ensureLayout(in textView: STTextView) {
        textView.textLayoutManager.ensureLayout(for: textView.textLayoutManager.documentRange)
        textView.layoutSubtreeIfNeeded()
    }

    static func lineFragmentFrame(containing range: NSRange, in textView: STTextView) throws -> CGRect {
        try lineFragment(containing: range, in: textView).typographicBounds.offsetBy(
            dx: layoutFragment(containing: range, in: textView).layoutFragmentFrame.minX,
            dy: layoutFragment(containing: range, in: textView).layoutFragmentFrame.minY
        )
    }

    static func lineFragment(containing range: NSRange, in textView: STTextView) throws -> NSTextLineFragment {
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

    static func layoutFragment(containing range: NSRange, in textView: STTextView) throws -> NSTextLayoutFragment {
        ensureLayout(in: textView)
        let textRange = try XCTUnwrap(NSTextRange(range, in: textView.textContentManager))
        return try XCTUnwrap(textView.textLayoutManager.textLayoutFragment(for: textRange.location))
    }

    static func uniquePasteboard(prefix: String = "PlainsongImagePresentation") -> NSPasteboard {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("\(prefix).\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        return pasteboard
    }

    static func readyOutcome(
        source _: String,
        resolvedPath: String,
        pixelWidth: Int = 320,
        pixelHeight: Int = 180,
        modificationDate: Date = Date(timeIntervalSinceReferenceDate: 1)
    ) -> EditorImageThumbnailOutcome {
        .ready(EditorImageThumbnail(
            pngData: validPNGData,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            resolvedWorkspaceRelativePath: resolvedPath,
            contentModificationDate: modificationDate
        ))
    }

    static func imageRegion(in source: String, literal: String) -> MarkdownInlineImageRegion {
        let storage = source as NSString
        let sourceRange = storage.range(of: literal)
        precondition(sourceRange.location != NSNotFound)
        let altTextRange = storage.range(of: "alt", options: [], range: sourceRange)
        let sourcePathRange = storage.range(of: "fixture.png", options: [], range: sourceRange)
        guard let region = MarkdownInlineImageRegion(
            in: source,
            sourceRange: sourceRange,
            altTextRange: altTextRange.location == NSNotFound
                ? NSRange(location: sourceRange.location + 2, length: 0)
                : altTextRange,
            sourcePathRange: sourcePathRange.location == NSNotFound
                ? NSRange(location: NSMaxRange(sourceRange) - 1, length: 0)
                : sourcePathRange
        ) else {
            preconditionFailure("Could not build test image region")
        }
        return region
    }

    static func text(in textView: STTextView) -> String {
        MarkdownTextView.textStorage(of: textView)?.string ?? textView.text ?? ""
    }

    static func assertNoObjectReplacementOrZeroWidth(
        _ value: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(value?.contains("\u{FFFC}") ?? true, file: file, line: line)
        XCTAssertFalse(value?.contains("\u{200B}") ?? true, file: file, line: line)
    }

    static func assertRawCopy(
        from textView: STTextView,
        source: String,
        range: NSRange,
        expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        textView.textSelection = range
        let pasteboard = uniquePasteboard(prefix: "PlainsongImageNativeCopy")
        XCTAssertTrue(
            textView.writeSelection(to: pasteboard, types: [.rtf, .string]),
            file: file,
            line: line
        )
        let plain = pasteboard.string(forType: .string)
        XCTAssertEqual(plain, expected, file: file, line: line)
        XCTAssertEqual((source as NSString).substring(with: range), expected, file: file, line: line)
        assertNoObjectReplacementOrZeroWidth(plain, file: file, line: line)

        let rtfData = try XCTUnwrap(pasteboard.data(forType: .rtf), file: file, line: line)
        var documentAttributes: NSDictionary?
        let copiedRTF = try NSAttributedString(
            data: rtfData,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: &documentAttributes
        )
        XCTAssertEqual(Data(copiedRTF.string.utf8), Data(expected.utf8), file: file, line: line)
        assertNoObjectReplacementOrZeroWidth(copiedRTF.string, file: file, line: line)
        copiedRTF.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: copiedRTF.length)
        ) { attachment, _, _ in
            XCTAssertNil(attachment, "Rich copy must contain raw Markdown", file: file, line: line)
        }
    }

    private static var validPNGData: Data {
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { bounds in
            NSColor.systemOrange.setFill()
            NSBezierPath(rect: bounds).fill()
            return true
        }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:])
        else {
            preconditionFailure("Could not make test PNG")
        }
        return data
    }

    enum TestError: Error {
        case timeout
    }
}
