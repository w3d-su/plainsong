import AppKit

/// TextKit 2 projection used only by the non-user-facing WYSIWYG development hook.
///
/// The backing NSTextStorage remains exact Markdown. Folded delimiters become equal-length
/// U+200B runs, while active image spans become one U+FFFC attachment plus equal-length
/// U+200B padding only inside the ephemeral paragraph copy.
final class WYSIWYGZeroWidthTextContentStorageDelegate: NSObject, NSTextContentStorageDelegate {
    weak var previousDelegate: NSTextContentStorageDelegate?
    var imagePresentationGeneration: UInt64?

    init(previousDelegate: NSTextContentStorageDelegate? = nil) {
        self.previousDelegate = previousDelegate
        super.init()
    }

    func textContentStorage(
        _ textContentStorage: NSTextContentStorage,
        textParagraphWith range: NSRange
    ) -> NSTextParagraph? {
        guard let textStorage = textContentStorage.textStorage,
              let paragraph = textStorage.attributedSubstring(from: range)
              .mutableCopy() as? NSMutableAttributedString
        else {
            return nil
        }

        var foldedRanges: [NSRange] = []
        var imageMarkers: [(range: NSRange, marker: WYSIWYGImagePresentationMarker)] = []
        paragraph.enumerateAttributes(
            in: NSRange(location: 0, length: paragraph.length)
        ) { attributes, attributeRange, _ in
            if WYSIWYGInlineFoldPresentation.containsFoldedDelimiterAttributes(attributes) {
                foldedRanges.append(attributeRange)
            }
        }
        paragraph.enumerateAttribute(
            WYSIWYGImagePresentationMarker.attribute,
            in: NSRange(location: 0, length: paragraph.length)
        ) { value, attributeRange, _ in
            if let marker = value as? WYSIWYGImagePresentationMarker,
               marker.generation == imagePresentationGeneration
            {
                imageMarkers.append((attributeRange, marker))
            }
        }

        guard !foldedRanges.isEmpty || !imageMarkers.isEmpty else {
            return previousDelegate?.textContentStorage?(
                textContentStorage,
                textParagraphWith: range
            )
        }

        for foldedRange in foldedRanges {
            paragraph.mutableString.replaceCharacters(
                in: foldedRange,
                with: String(repeating: "\u{200B}", count: foldedRange.length)
            )
        }

        for imageMarker in imageMarkers where imageMarker.range.length > 0 {
            paragraph.mutableString.replaceCharacters(
                in: imageMarker.range,
                with: "\u{FFFC}" + String(
                    repeating: "\u{200B}",
                    count: imageMarker.range.length - 1
                )
            )
            paragraph.addAttribute(
                .attachment,
                value: imageMarker.marker.makeAttachment(),
                range: NSRange(location: imageMarker.range.location, length: 1)
            )
            // Run-local font metrics reserve the image canvas without imposing the
            // attachment height on other wrapped visual lines in the paragraph.
            paragraph.addAttribute(
                .font,
                value: imageMarker.marker.lineHeightFont,
                range: NSRange(location: imageMarker.range.location, length: 1)
            )
        }

        precondition(
            paragraph.length == range.length,
            "WYSIWYG projection must preserve every raw UTF-16 offset"
        )
        return NSTextParagraph(attributedString: paragraph)
    }
}
