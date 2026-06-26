import AppKit

/// TextKit 2 projection used only by the non-user-facing WYSIWYG development hook.
///
/// The backing NSTextStorage remains exact Markdown. For layout, folded delimiter
/// characters are projected to equal-length U+200B runs inside NSTextParagraphs so
/// TextKit produces zero-advance geometry without object-replacement characters.
final class WYSIWYGZeroWidthTextContentStorageDelegate: NSObject, NSTextContentStorageDelegate {
    weak var previousDelegate: NSTextContentStorageDelegate?

    init(previousDelegate: NSTextContentStorageDelegate? = nil) {
        self.previousDelegate = previousDelegate
        super.init()
    }

    func textContentStorage(
        _ textContentStorage: NSTextContentStorage,
        textParagraphWith range: NSRange
    ) -> NSTextParagraph? {
        guard let textStorage = textContentStorage.textStorage else {
            return nil
        }

        let paragraph = textStorage.attributedSubstring(from: range).mutableCopy() as! NSMutableAttributedString
        var foldedRanges: [NSRange] = []
        paragraph.enumerateAttributes(
            in: NSRange(location: 0, length: paragraph.length)
        ) { attributes, foldedRange, _ in
            guard WYSIWYGInlineFoldPresentation.containsFoldedDelimiterAttributes(attributes) else {
                return
            }
            foldedRanges.append(foldedRange)
        }

        guard !foldedRanges.isEmpty else {
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

        return NSTextParagraph(attributedString: paragraph)
    }
}
