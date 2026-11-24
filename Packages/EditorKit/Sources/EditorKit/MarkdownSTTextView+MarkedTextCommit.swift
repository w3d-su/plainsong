import AppKit
import STTextView

extension MarkdownSTTextView {
    /// Moves the caret behind a committed composition, but only when the storage holds
    /// exactly that commit. A rejected write, or an editing behavior that wrote something
    /// else (list continuation, auto-pairing, skip-over), has already placed the caret.
    func ensureInsertionPointAfterInsertedText(
        _ string: Any,
        replacing replacedRange: NSRange,
        lengthBeforeInsertion: Int?
    ) {
        guard let insertedLength = Self.utf16Length(ofInsertedText: string),
              let lengthBeforeInsertion,
              let text = (textContentManager as? NSTextContentStorage)?.textStorage?.mutableString,
              text.length == lengthBeforeInsertion - replacedRange.length + insertedLength
        else {
            return
        }
        let insertedRange = NSRange(location: replacedRange.location, length: insertedLength)
        let inserted = (string as? NSAttributedString)?.string ?? string as? String
        guard NSMaxRange(insertedRange) <= text.length,
              text.substring(with: insertedRange) == inserted
        else {
            return
        }

        textSelection = NSRange(location: NSMaxRange(insertedRange), length: 0)
    }

    static func utf16Length(ofInsertedText string: Any) -> Int? {
        switch string {
        case let string as String:
            string.utf16.count
        case let attributedString as NSAttributedString:
            attributedString.length
        default:
            nil
        }
    }
}
