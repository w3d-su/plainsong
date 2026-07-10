import AppKit

/// TextKit 2 projection used only by the non-user-facing WYSIWYG development hook.
///
/// The backing NSTextStorage remains exact Markdown. For layout, folded delimiter
/// characters are projected to equal-length U+200B runs inside NSTextParagraphs. The I0
/// image spike may add one attachment character only to an ephemeral paragraph; backing,
/// copy, and accessibility output remain free of object-replacement characters.
final class WYSIWYGZeroWidthTextContentStorageDelegate: NSObject, NSTextContentStorageDelegate {
    weak var previousDelegate: NSTextContentStorageDelegate?
    private(set) var isImageAttachmentI0SpikeEnabled = false
    private(set) var isImageAttachmentI0SpikeRevealed = false

    init(previousDelegate: NSTextContentStorageDelegate? = nil) {
        self.previousDelegate = previousDelegate
        super.init()
    }

    /// I0 mechanism spike only. This deliberately recognizes one literal fixture and is
    /// not wired to the public editor presentation modes.
    func setImageAttachmentI0SpikeEnabled(_ isEnabled: Bool) {
        isImageAttachmentI0SpikeEnabled = isEnabled
        isImageAttachmentI0SpikeRevealed = false
    }

    func revealImageAttachmentI0Spike() -> Bool {
        guard isImageAttachmentI0SpikeEnabled,
              !isImageAttachmentI0SpikeRevealed
        else {
            return false
        }

        isImageAttachmentI0SpikeRevealed = true
        return true
    }

    func imageAttachmentI0SpikeSourceRange(in textContentStorage: NSTextContentStorage) -> NSRange? {
        guard isImageAttachmentI0SpikeEnabled,
              !isImageAttachmentI0SpikeRevealed,
              let textStorage = textContentStorage.textStorage
        else {
            return nil
        }

        let range = (textStorage.string as NSString).range(of: WYSIWYGImageAttachmentI0Spike.source)
        var markerRange = NSRange(location: 0, length: 0)
        guard range.location != NSNotFound,
              textStorage.attribute(
                  WYSIWYGImageAttachmentI0Spike.markerAttribute,
                  at: range.location,
                  longestEffectiveRange: &markerRange,
                  in: range
              ) as? Bool == true,
              markerRange == range
        else {
            return nil
        }
        return range
    }

    func textContentStorage(
        _ textContentStorage: NSTextContentStorage,
        textParagraphWith range: NSRange
    ) -> NSTextParagraph? {
        guard let textStorage = textContentStorage.textStorage else {
            return nil
        }

        guard let paragraph = textStorage.attributedSubstring(from: range)
            .mutableCopy() as? NSMutableAttributedString
        else {
            return nil
        }
        var foldedRanges: [NSRange] = []
        paragraph.enumerateAttributes(
            in: NSRange(location: 0, length: paragraph.length)
        ) { attributes, foldedRange, _ in
            guard WYSIWYGInlineFoldPresentation.containsFoldedDelimiterAttributes(attributes) else {
                return
            }
            foldedRanges.append(foldedRange)
        }

        let imageSourceRange = imageAttachmentI0SpikeSourceRange(in: paragraph)

        guard !foldedRanges.isEmpty || imageSourceRange != nil else {
            return previousDelegate?.textContentStorage?(
                textContentStorage,
                textParagraphWith: range
            )
        }

        // Folded paragraphs are owned by this projection: the layout copy differs
        // from the backing Markdown only where hidden delimiters become U+200B.
        for foldedRange in foldedRanges {
            let zeroWidthSpaces = String(repeating: "\u{200B}", count: foldedRange.length)
            paragraph.mutableString.replaceCharacters(in: foldedRange, with: zeroWidthSpaces)
        }

        if let imageSourceRange {
            paragraph.mutableString.replaceCharacters(
                in: imageSourceRange,
                with: "\u{FFFC}" + String(
                    repeating: "\u{200B}",
                    count: imageSourceRange.length - 1
                )
            )
            paragraph.addAttribute(
                .attachment,
                value: makeImageAttachmentI0Spike(),
                range: NSRange(location: imageSourceRange.location, length: 1)
            )
            // STTextView otherwise keeps an attachment-only run at the base font's
            // height. A run-local font supplies the attachment's vertical metrics
            // without imposing a paragraph-wide minimum on wrapped sibling lines.
            paragraph.addAttribute(
                .font,
                value: makeImageAttachmentI0SpikeLineHeightFont(),
                range: NSRange(location: imageSourceRange.location, length: 1)
            )
            precondition(
                paragraph.length == range.length,
                "I0 projection must preserve every raw UTF-16 offset"
            )
        }

        return NSTextParagraph(attributedString: paragraph)
    }

    private func imageAttachmentI0SpikeSourceRange(in paragraph: NSAttributedString) -> NSRange? {
        guard isImageAttachmentI0SpikeEnabled,
              !isImageAttachmentI0SpikeRevealed
        else {
            return nil
        }

        let range = (paragraph.string as NSString).range(of: WYSIWYGImageAttachmentI0Spike.source)
        var markerRange = NSRange(location: 0, length: 0)
        guard range.location != NSNotFound,
              paragraph.attribute(
                  WYSIWYGImageAttachmentI0Spike.markerAttribute,
                  at: range.location,
                  longestEffectiveRange: &markerRange,
                  in: range
              ) as? Bool == true,
              markerRange == range
        else {
            return nil
        }
        return range
    }

    private func makeImageAttachmentI0Spike() -> NSTextAttachment {
        let image = NSImage(
            size: WYSIWYGImageAttachmentI0Spike.attachmentSize,
            flipped: false
        ) { bounds in
            NSColor.systemOrange.setFill()
            NSBezierPath(rect: bounds).fill()
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(
            x: 0,
            y: -4,
            width: WYSIWYGImageAttachmentI0Spike.attachmentSize.width,
            height: WYSIWYGImageAttachmentI0Spike.attachmentSize.height
        )
        attachment.allowsTextAttachmentView = false
        return attachment
    }

    private func makeImageAttachmentI0SpikeLineHeightFont() -> NSFont {
        var pointSize: CGFloat = 1
        while pointSize <= WYSIWYGImageAttachmentI0Spike.attachmentSize.height {
            let font = NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
            let lineHeight = font.ascender - font.descender + font.leading
            if lineHeight >= WYSIWYGImageAttachmentI0Spike.attachmentSize.height {
                return font
            }
            pointSize += 0.5
        }
        return NSFont.monospacedSystemFont(
            ofSize: WYSIWYGImageAttachmentI0Spike.attachmentSize.height,
            weight: .regular
        )
    }
}

/// Throwaway constants for the image-thumbnail I0 rendering-mechanism spike.
enum WYSIWYGImageAttachmentI0Spike {
    static let source = "![alt](fixture.png)"
    static let attachmentSize = NSSize(width: 80, height: 48)
    static let markerAttribute = NSAttributedString.Key("app.plainsong.wysiwyg.imageAttachmentI0Spike")
}
