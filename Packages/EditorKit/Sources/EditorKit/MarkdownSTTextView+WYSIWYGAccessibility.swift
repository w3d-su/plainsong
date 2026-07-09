import AppKit

extension MarkdownSTTextView {
    override func accessibilitySelectedText() -> String? {
        guard wysiwygZeroWidthContentStorageDelegate != nil,
              let textStorage = (textContentManager as? NSTextContentStorage)?.textStorage
        else {
            return super.accessibilitySelectedText()
        }

        let rawRanges = textLayoutManager.textSelections
            .flatMap(\.textRanges)
            .filter { !$0.isEmpty }
            .map { NSRange($0, in: textContentManager).clamped(toLength: textStorage.length) }
            .sorted { $0.location < $1.location }

        return rawRanges
            .map { (textStorage.string as NSString).substring(with: $0) }
            .joined(separator: "\n")
    }
}
