import SyntaxKit
import UIKit

@MainActor
enum IOSHighlightPresenter {
    /// Paints syntax attributes only. Selection, scroll, undo, and typing attributes stay.
    static func apply(
        tokens: [MarkdownSyntaxToken],
        coveredRange: NSRange,
        expectedFragment: String,
        theme: IOSEditorTheme,
        to textView: IOSMarkdownTextView
    ) -> Bool {
        guard textView.markedTextRange == nil else { return false }
        let storage = textView.textStorage
        guard let fragment = IOSTextRanges.substring(storage.string, range: coveredRange),
              ExactSourceFragment.matches(fragment, expectedFragment)
        else {
            return false
        }

        let selectedRange = textView.selectedRange
        let contentOffset = textView.contentOffset
        let typingAttributes = textView.typingAttributes
        textView.suppressesUndoRegistration = true
        defer {
            textView.suppressesUndoRegistration = false
            if textView.selectedRange != selectedRange {
                textView.selectedRange = selectedRange
            }
            if textView.contentOffset != contentOffset {
                textView.contentOffset = contentOffset
            }
            textView.typingAttributes = typingAttributes
        }

        storage.beginEditing()
        clearOwnedAttributes(in: coveredRange, storage: storage)
        for token in tokens {
            guard let range = intersection(token.range, coveredRange), range.length > 0 else { continue }
            storage.addAttributes(
                [
                    IOSSyntaxAttribute.key: IOSSyntaxAttribute.token(for: token.kind),
                    .foregroundColor: theme.color(for: token.kind),
                    .font: theme.font(for: token.kind),
                ],
                range: range
            )
        }
        storage.endEditing()
        return true
    }

    static func clearOwnedAttributes(in range: NSRange, of textView: IOSMarkdownTextView) {
        guard range.length > 0 else { return }
        textView.suppressesUndoRegistration = true
        textView.textStorage.beginEditing()
        clearOwnedAttributes(in: range, storage: textView.textStorage)
        textView.textStorage.endEditing()
        textView.suppressesUndoRegistration = false
    }

    private static func clearOwnedAttributes(in range: NSRange, storage: NSTextStorage) {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        var owned: [NSRange] = []
        storage.enumerateAttribute(IOSSyntaxAttribute.key, in: range) { value, attributeRange, _ in
            guard value != nil else { return }
            owned.append(attributeRange)
        }
        for attributeRange in owned {
            storage.removeAttribute(IOSSyntaxAttribute.key, range: attributeRange)
            storage.removeAttribute(.foregroundColor, range: attributeRange)
            storage.removeAttribute(.font, range: attributeRange)
        }
    }

    private static func intersection(_ lhs: NSRange, _ rhs: NSRange) -> NSRange? {
        let start = max(lhs.location, rhs.location)
        let end = min(NSMaxRange(lhs), NSMaxRange(rhs))
        guard end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }
}

enum ExactSourceFragment {
    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        (lhs as NSString).compare(rhs, options: .literal) == .orderedSame
    }
}
