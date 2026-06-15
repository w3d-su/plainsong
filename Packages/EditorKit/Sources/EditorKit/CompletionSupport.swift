import AppKit
import MarkdownCore
import STTextView

@MainActor
final class MarkdownCompletionItem: @preconcurrency STCompletionItem {
    let id: String
    let completion: Completion

    init(completion: Completion) {
        id = completion.id
        self.completion = completion
    }

    var view: NSView {
        let labelText = completion.label
        let detailText = completion.kind.displayName
        return Self.makeView(labelText: labelText, detailText: detailText)
    }

    private static func makeView(labelText: String, detailText: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)

        let label = NSTextField(labelWithString: labelText)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle

        let detail = NSTextField(labelWithString: detailText)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail

        row.addArrangedSubview(label)
        row.addArrangedSubview(detail)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detail.setContentHuggingPriority(.required, for: .horizontal)
        row.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        return row
    }
}

@MainActor
enum EditorCompletionSupport {
    static let recentCompletionLimit = 20

    static func shouldTriggerCompletion(
        replacementString: String,
        emojiShortcodePrefixBeforeChange: @autoclosure () -> String?,
        fileKind: FileKind
    ) -> Bool {
        guard replacementString.utf16.count == 1 else { return false }

        switch replacementString {
        case "#", ">", "-", "`", "(", "/":
            return true
        case "<":
            return fileKind == .mdx
        default:
            return continuesEmojiShortcode(
                replacementString: replacementString,
                emojiShortcodePrefixBeforeChange: emojiShortcodePrefixBeforeChange
            )
        }
    }

    static func emojiShortcodePrefixBeforeSelection(
        in textView: STTextView,
        selection proposedSelection: NSRange? = nil,
        limit: Int = 64
    ) -> String? {
        guard let textStorage = MarkdownTextView.textStorage(of: textView) else {
            return nil
        }

        let storage = textStorage.mutableString
        let rawSelection = proposedSelection ?? textView.selectedRange()
        guard rawSelection.location != NSNotFound else {
            return nil
        }

        let cursor = min(max(rawSelection.location, 0), storage.length)
        var location = cursor
        var remaining = limit
        while location > 0, remaining > 0 {
            let previousLocation = location - 1
            let previous = storage.character(at: previousLocation)
            if previous == 58 {
                return storage.substring(with: NSRange(
                    location: previousLocation + 1,
                    length: cursor - previousLocation - 1
                ))
            }
            if previous == 10 || previous == 13 || previous == 9 || previous == 32 {
                return nil
            }
            location = previousLocation
            remaining -= 1
        }

        return nil
    }

    static func insert(
        _ completion: Completion,
        into textView: STTextView,
        editingGuard: EditingBehaviorGuard
    ) {
        guard !editingGuard.isApplying else { return }
        let replacementRange = completion.replacementRange.clamped(
            toLength: MarkdownTextView.textStorage(of: textView)?.length ?? 0
        )

        editingGuard.isApplying = true
        textView.insertText(completion.insertText, replacementRange: replacementRange)
        editingGuard.isApplying = false

        let selectionLocation = replacementRange.location + (completion.insertText as NSString).length
        textView.textSelection = NSRange(location: selectionLocation, length: 0)
    }

    static func recentCompletionIDs(
        selecting completionID: String,
        existing: [String],
        limit: Int = recentCompletionLimit
    ) -> [String] {
        var updated = [completionID]
        for id in existing where id != completionID {
            updated.append(id)
            if updated.count == limit {
                break
            }
        }
        return updated
    }

    private static func continuesEmojiShortcode(
        replacementString: String,
        emojiShortcodePrefixBeforeChange: () -> String?
    ) -> Bool {
        guard replacementString.rangeOfCharacter(from: .alphanumerics) != nil else {
            return false
        }

        guard let query = emojiShortcodePrefixBeforeChange() else {
            return false
        }

        // emojiShortcodePrefixBeforeSelection returns only text after the trigger colon.
        return query.utf16.count >= 1
    }
}

private extension Completion.Kind {
    var displayName: String {
        switch self {
        case .snippet:
            "Snippet"
        case .language:
            "Language"
        case .filePath:
            "File"
        case .imagePath:
            "Image"
        case .headingAnchor:
            "Heading"
        case .emoji:
            "Emoji"
        case .frontmatterKey:
            "Frontmatter"
        case .component:
            "Component"
        }
    }
}
