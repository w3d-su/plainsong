import Foundation
import MarkdownCore

enum ExactUTF16Text {
    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        let lhsUTF16 = lhs.utf16
        let rhsUTF16 = rhs.utf16
        guard lhsUTF16.count == rhsUTF16.count else {
            return false
        }

        return lhsUTF16.elementsEqual(rhsUTF16)
    }
}

struct MarkdownTextViewUpdatePolicy {
    let isUserEditing: Bool
    let hasMarkedText: Bool
    private let incomingTextEqualsCurrentText: () -> Bool

    /// `incomingTextEqualsCurrentText` is an autoclosure so the O(n) comparison is
    /// skipped entirely on the typing hot path, where `isUserEditing` already decides.
    init(
        isUserEditing: Bool,
        hasMarkedText: Bool,
        incomingTextEqualsCurrentText: @escaping @autoclosure () -> Bool
    ) {
        self.isUserEditing = isUserEditing
        self.hasMarkedText = hasMarkedText
        self.incomingTextEqualsCurrentText = incomingTextEqualsCurrentText
    }

    var shouldApplyIncomingText: Bool {
        guard !isUserEditing, !hasMarkedText else {
            return false
        }

        return !incomingTextEqualsCurrentText()
    }
}

/// Debounced highlighter output. Equality is by revision so SwiftUI prop diffing
/// never compares whole attributed strings (O(n)).
struct HighlightedText: Equatable {
    let revision: Int
    let range: NSRange
    let text: AttributedString
    let foldPlan: WYSIWYGFoldPlan?

    init(revision: Int, range: NSRange, text: AttributedString, foldPlan: WYSIWYGFoldPlan? = nil) {
        self.revision = revision
        self.range = range
        self.text = text
        self.foldPlan = foldPlan
    }

    init(revision: Int, text: AttributedString, foldPlan: WYSIWYGFoldPlan? = nil) {
        self.revision = revision
        self.text = text
        self.foldPlan = foldPlan
        range = NSRange(location: 0, length: NSAttributedString(text).length)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.revision == rhs.revision
    }
}
