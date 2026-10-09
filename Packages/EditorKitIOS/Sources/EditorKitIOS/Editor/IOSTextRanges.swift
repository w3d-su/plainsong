import UIKit

enum IOSTextRanges {
    static func utf16Length(of text: String) -> Int {
        (text as NSString).length
    }

    static func substring(_ text: String, range: NSRange) -> String? {
        let storage = text as NSString
        guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= storage.length else {
            return nil
        }
        return storage.substring(with: range)
    }

    static func contains(_ range: NSRange, length: Int) -> Bool {
        range.location >= 0 && range.length >= 0 && NSMaxRange(range) <= length
    }

    static func clamped(_ range: NSRange, length: Int) -> NSRange {
        guard length > 0 else { return NSRange(location: 0, length: 0) }
        let location = min(max(range.location, 0), length)
        let maxLength = length - location
        return NSRange(location: location, length: min(max(range.length, 0), maxLength))
    }

    static func textRange(for range: NSRange, in textView: UITextView) -> UITextRange? {
        guard let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
              let end = textView.position(from: start, offset: range.length)
        else {
            return nil
        }
        return textView.textRange(from: start, to: end)
    }

    static func nsRange(for textRange: NSTextRange, content: NSTextContentManager?) -> NSRange? {
        guard let content else { return nil }
        let origin = content.documentRange.location
        let start = content.offset(from: origin, to: textRange.location)
        let end = content.offset(from: origin, to: textRange.endLocation)
        guard start >= 0, end >= start else { return nil }
        return NSRange(location: start, length: end - start)
    }
}
