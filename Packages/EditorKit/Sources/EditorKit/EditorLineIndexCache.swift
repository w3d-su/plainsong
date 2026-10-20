import AppKit
import STTextView

/// The one source-line index of a text view, shared by scroll sync and the line-number
/// gutter so neither rescans the document per keystroke.
///
/// Native replacements are applied in place from `textWillChange`, before the content
/// storage changes. Any change that bypassed it drops the index at its change
/// notification, and the next reader rebuilds it once.
@MainActor
final class EditorLineIndexCache {
    private weak var textView: STTextView?
    private var index: EditorScrollLineIndex?
    /// Forwarded replacements whose `textDidChangeNotification` has not arrived yet.
    private var editsAwaitingDidChange = 0
    private var textObserver: CoordinatorNotificationObserver?
    /// Runs after the cache has accounted for each text change (the line-number gutter).
    var textDidChangeHandler: (() -> Void)?
    /// Full scans of the document; typing must not add any.
    private(set) var rebuildCount = 0

    init(textView: STTextView) {
        self.textView = textView
        textObserver = CoordinatorNotificationObserver(NotificationCenter.default.addObserver(
            forName: STTextView.textDidChangeNotification,
            object: textView,
            queue: .main
        ) { [weak self] _ in
            // Delivered on the main queue. A change that was not forwarded through
            // `textWillChange` invalidates here, before a same-turn source installation
            // can issue navigation into the new text.
            MainActor.assumeIsolated {
                self?.textDidChange()
            }
        })
    }

    /// The text view's own cache when it has one; a plain STTextView gets a private one.
    static func cache(for textView: STTextView) -> EditorLineIndexCache {
        (textView as? MarkdownSTTextView)?.lineIndexCache ?? EditorLineIndexCache(textView: textView)
    }

    /// `range` in pre-edit UTF-16 offsets. Call once per native replacement.
    func textWillChange(in range: NSRange, replacementString: String) {
        editsAwaitingDidChange += 1
        guard var index else { return }
        // Release the stored copy first so the edit mutates a uniquely referenced buffer.
        self.index = nil
        if index.replaceCharacters(in: range, with: replacementString) {
            self.index = index
        }
    }

    func currentIndex() -> EditorScrollLineIndex {
        // `mutableString` reads the storage in place, without bridging it to `String`.
        let text = textView.map { textView -> NSString in
            MarkdownTextView.textStorage(of: textView)?.mutableString
                ?? (textView.text ?? "") as NSString
        } ?? ""
        // The length check is O(1) and catches any edit that bypassed `textWillChange`.
        if let index, index.textUTF16Count == text.length {
            return index
        }

        let newIndex = EditorScrollLineIndex(utf16: text)
        rebuildCount += 1
        index = newIndex
        return newIndex
    }

    private func textDidChange() {
        if editsAwaitingDidChange > 0 {
            editsAwaitingDidChange -= 1
        } else {
            index = nil
        }
        textDidChangeHandler?()
    }
}
