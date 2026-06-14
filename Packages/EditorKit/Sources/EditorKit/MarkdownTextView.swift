import AppKit
import MarkdownCore
import STTextView
import SwiftUI

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
    let text: AttributedString

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.revision == rhs.revision
    }
}

/// STTextView wrapper with a String-only typing hot path.
///
/// Per-keystroke work must never convert the whole document between
/// String/NSAttributedString/AttributedString — that bridging caused visible lag on
/// 1 MB documents. Plain `String` flows through `text`; styling arrives separately
/// (and rarely) via `styledText` and is applied in place.
struct MarkdownTextView: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Binding private var text: String
    @Binding private var selection: NSRange?

    private let styledText: HighlightedText?
    private let showsLineNumbers: Bool
    private let font: NSFont
    private let lineHeightMultiple: CGFloat
    private let scrollProxy: EditorScrollProxy?
    private let commandProxy: EditorCommandProxy?

    init(
        text: Binding<String>,
        styledText: HighlightedText?,
        selection: Binding<NSRange?>,
        showsLineNumbers: Bool,
        scrollProxy: EditorScrollProxy? = nil,
        commandProxy: EditorCommandProxy? = nil,
        font: NSFont = MarkdownSyntaxHighlighter.defaultFont,
        lineHeightMultiple: CGFloat = 1.25
    ) {
        _text = text
        _selection = selection
        self.styledText = styledText
        self.showsLineNumbers = showsLineNumbers
        self.scrollProxy = scrollProxy
        self.commandProxy = commandProxy
        self.font = font
        self.lineHeightMultiple = lineHeightMultiple
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = STTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? STTextView else {
            assertionFailure("Expected STTextView.scrollableTextView() to contain an STTextView")
            return scrollView
        }

        textView.textDelegate = context.coordinator
        textView.highlightSelectedLine = true
        textView.isHorizontallyResizable = false
        textView.showsLineNumbers = showsLineNumbers
        textView.textSelection = NSRange()
        textView.font = font
        textView.gutterView?.font = font
        textView.gutterView?.textColor = .secondaryLabelColor

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.setParagraphStyle(.default)
        paragraphStyle.lineHeightMultiple = lineHeightMultiple
        textView.defaultParagraphStyle = paragraphStyle

        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled

        context.coordinator.isUpdating = true
        textView.text = text
        context.coordinator.isUpdating = false
        context.coordinator.attachScrollProxy(scrollProxy, to: textView)
        context.coordinator.attachCommandProxy(commandProxy, to: textView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? STTextView else {
            assertionFailure("Expected MarkdownTextView to update an STTextView-backed scroll view")
            return
        }

        context.coordinator.attachScrollProxy(scrollProxy, to: textView)
        context.coordinator.attachCommandProxy(commandProxy, to: textView)

        let policy = MarkdownTextViewUpdatePolicy(
            isUserEditing: context.coordinator.isUserEditing,
            hasMarkedText: textView.hasMarkedText(),
            incomingTextEqualsCurrentText: Self.plainTextMatches(textView, text)
        )

        if policy.shouldApplyIncomingText {
            context.coordinator.isUpdating = true
            let currentSelection = textView.selectedRange()
            textView.text = text
            textView.textSelection = currentSelection.clamped(toLength: (text as NSString).length)
            context.coordinator.isUpdating = false
        }

        applyStyledTextIfNeeded(to: textView, coordinator: context.coordinator)
        context.coordinator.isUserEditing = false

        let shouldApplySelection = selection.map { proposedSelection in
            !textView.hasMarkedText() && textView.textSelection != proposedSelection
        } ?? false

        if shouldApplySelection, let selection {
            let textLength = Self.textStorage(of: textView)?.length ?? 0
            textView.textSelection = selection.clamped(toLength: textLength)
        }

        if textView.isEditable != isEnabled {
            textView.isEditable = isEnabled
        }
        if textView.isSelectable != isEnabled {
            textView.isSelectable = isEnabled
        }
        if textView.showsLineNumbers != showsLineNumbers {
            textView.showsLineNumbers = showsLineNumbers
        }
        // No unconditional needsLayout/needsDisplay here: forcing a relayout pass on
        // every SwiftUI update (i.e. every keystroke) is wasted work — text and
        // attribute edits already invalidate exactly what changed.
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        guard let textView = scrollView.documentView as? STTextView else { return }
        coordinator.detachCommandProxy(from: textView)
        coordinator.detachScrollProxy()
    }

    /// Applies the debounced highlight as an in-place attribute pass: the caret, IME
    /// state, and scroll position survive because the characters never change. Stale
    /// styling (the text moved on) is dropped — a newer revision is already scheduled.
    private func applyStyledTextIfNeeded(to textView: STTextView, coordinator: Coordinator) {
        guard let styledText,
              styledText.revision != coordinator.lastAppliedHighlightRevision,
              !coordinator.isUserEditing,
              !textView.hasMarkedText(),
              let textStorage = Self.textStorage(of: textView)
        else {
            return
        }

        coordinator.lastAppliedHighlightRevision = styledText.revision
        let incoming = NSAttributedString(styledText.text)
        guard textStorage.string == incoming.string else {
            return
        }

        coordinator.isUpdating = true
        textStorage.beginEditing()
        incoming.enumerateAttributes(
            in: NSRange(location: 0, length: incoming.length)
        ) { attributes, range, _ in
            textStorage.setAttributes(attributes, range: range)
        }
        textStorage.endEditing()
        textView.needsDisplay = true
        coordinator.isUpdating = false
    }

    @MainActor
    static func textStorage(of textView: STTextView) -> NSTextStorage? {
        (textView.textContentManager as? NSTextContentStorage)?.textStorage
    }

    /// Cheap length check first; the full comparison only runs when lengths match.
    @MainActor
    static func plainTextMatches(_ textView: STTextView, _ candidate: String) -> Bool {
        guard let textStorage = textStorage(of: textView) else {
            return false
        }
        guard textStorage.length == candidate.utf16.count else {
            return false
        }
        return textStorage.string == candidate
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, selection: $selection)
    }

    @MainActor
    final class Coordinator: @preconcurrency STTextViewDelegate {
        @Binding var text: String
        @Binding var selection: NSRange?
        var isUpdating = false
        var isUserEditing = false
        var lastAppliedHighlightRevision: Int?
        private var scrollProxy: EditorScrollProxy?
        private var commandProxy: EditorCommandProxy?
        private let editingBehaviorGuard = EditingBehaviorGuard()

        init(text: Binding<String>, selection: Binding<NSRange?>) {
            _text = text
            _selection = selection
        }

        func attachScrollProxy(_ proxy: EditorScrollProxy?, to textView: STTextView) {
            if scrollProxy !== proxy {
                scrollProxy?.detach()
                scrollProxy = proxy
            }

            proxy?.attach(to: textView)
        }

        func detachScrollProxy() {
            scrollProxy?.detach()
            scrollProxy = nil
        }

        func attachCommandProxy(_ proxy: EditorCommandProxy?, to textView: STTextView) {
            if commandProxy !== proxy {
                commandProxy?.detach(from: textView)
                commandProxy = proxy
            }

            proxy?.attach(
                to: textView,
                fileKind: proxy?.currentFileKind() ?? .markdown
            ) { [weak self, weak textView] command in
                guard let self, let textView else { return }
                performCommand(command, in: textView)
            }
        }

        func detachCommandProxy(from textView: STTextView) {
            commandProxy?.detach(from: textView)
            commandProxy = nil
        }

        private func performCommand(_ command: MarkdownEditCommand, in textView: STTextView) {
            EditingBehaviorsSupport.applyCommand(
                command,
                to: textView,
                editingGuard: editingBehaviorGuard
            )
        }

        func textViewDidChangeText(_ notification: Notification) {
            guard !isUpdating, let textView = notification.object as? STTextView else {
                return
            }

            isUserEditing = true
            // `textStorage.string` is a lazily bridged ("foreign") String backed by
            // CFStorage — every downstream comparison and count would crawl through
            // ObjC. One eager transcode here makes all later operations native-fast
            // (confirmed by Time Profiler: _StringGuts.foreign* + CFStorageGetConstValue).
            var newText = MarkdownTextView.textStorage(of: textView)?.string ?? textView.text ?? ""
            newText.makeContiguousUTF8()
            text = newText
        }

        func textView(
            _ textView: STTextView,
            shouldChangeTextIn affectedCharRange: NSTextRange,
            replacementString: String?
        ) -> Bool {
            EditingBehaviorsSupport.handleProposedChange(
                in: textView,
                affectedRange: affectedCharRange,
                replacementString: replacementString,
                fileKind: commandProxy?.currentFileKind() ?? .markdown,
                editingGuard: editingBehaviorGuard
            )
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isUpdating, let textView = notification.object as? STTextView else {
                return
            }

            selection = textView.selectedRange()
        }
    }
}

private extension NSRange {
    func clamped(toLength length: Int) -> NSRange {
        guard location != NSNotFound else {
            return self
        }

        let clampedLocation = min(max(location, 0), length)
        let clampedLength = min(max(self.length, 0), length - clampedLocation)
        return NSRange(location: clampedLocation, length: clampedLength)
    }
}
