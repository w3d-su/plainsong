import AppKit
import MarkdownCore
import STTextView

final class MarkdownCompletionItem: STCompletionItem {
    let id: String
    let completion: Completion

    init(completion: Completion) {
        id = completion.id
        self.completion = completion
    }

    var view: NSView {
        let labelText = completion.label
        let detailText = completion.kind.displayName
        return MainActor.assumeIsolated {
            Self.makeView(labelText: labelText, detailText: detailText)
        }
    }

    @MainActor
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
    static func shouldTriggerCompletion(
        replacementString: String,
        textBeforeChange: String,
        selection: NSRange,
        fileKind: FileKind
    ) -> Bool {
        guard replacementString.utf16.count == 1 else { return false }

        switch replacementString {
        case "#", ">", "-", "`", "(", "/", ":":
            return true
        case "<":
            return fileKind == .mdx
        default:
            return continuesEmojiShortcode(
                replacementString: replacementString,
                textBeforeChange: textBeforeChange,
                selection: selection
            )
        }
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

    private static func continuesEmojiShortcode(
        replacementString: String,
        textBeforeChange: String,
        selection: NSRange
    ) -> Bool {
        guard replacementString.rangeOfCharacter(from: .alphanumerics) != nil else {
            return false
        }

        let storage = textBeforeChange as NSString
        let cursor = min(max(selection.location, 0), storage.length)
        let line = linePrefix(in: textBeforeChange, cursor: cursor)
        guard let colon = line.range(of: ":", options: .backwards) else {
            return false
        }

        let query = String(line[colon.upperBound...])
        return query.utf16.count >= 1 && !query.contains(where: { $0.isWhitespace || $0 == ":" })
    }

    private static func linePrefix(in text: String, cursor: Int) -> String {
        let storage = text as NSString
        var lineStart = cursor
        while lineStart > 0 {
            let previous = storage.character(at: lineStart - 1)
            if previous == 10 || previous == 13 {
                break
            }
            lineStart -= 1
        }

        return storage.substring(with: NSRange(location: lineStart, length: cursor - lineStart))
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
