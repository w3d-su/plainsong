import AppKit
import STTextView
import SwiftUI

struct MarkdownTextViewUpdatePolicy {
    let isUserEditing: Bool
    let hasMarkedText: Bool
    private let incomingTextEqualsCurrentText: () -> Bool

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

struct MarkdownTextView: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Binding private var text: AttributedString
    @Binding private var selection: NSRange?

    private let showsLineNumbers: Bool
    private let font: NSFont
    private let lineHeightMultiple: CGFloat

    init(
        text: Binding<AttributedString>,
        selection: Binding<NSRange?>,
        showsLineNumbers: Bool,
        font: NSFont = MarkdownSyntaxHighlighter.defaultFont,
        lineHeightMultiple: CGFloat = 1.25
    ) {
        _text = text
        _selection = selection
        self.showsLineNumbers = showsLineNumbers
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
        textView.attributedText = NSAttributedString(text)
        context.coordinator.isUpdating = false

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? STTextView else {
            assertionFailure("Expected MarkdownTextView to update an STTextView-backed scroll view")
            return
        }
        var resolvedCurrentText: NSAttributedString?
        var resolvedIncomingText: NSAttributedString?
        func currentText() -> NSAttributedString {
            if let resolvedCurrentText {
                return resolvedCurrentText
            }

            let currentText = textView.attributedText ?? NSAttributedString()
            resolvedCurrentText = currentText
            return currentText
        }

        func incomingText() -> NSAttributedString {
            if let resolvedIncomingText {
                return resolvedIncomingText
            }

            let incomingText = NSAttributedString(text)
            resolvedIncomingText = incomingText
            return incomingText
        }

        let policy = MarkdownTextViewUpdatePolicy(
            isUserEditing: context.coordinator.isUserEditing,
            hasMarkedText: textView.hasMarkedText(),
            incomingTextEqualsCurrentText: currentText().isEqual(to: incomingText())
        )

        if policy.shouldApplyIncomingText {
            let incomingText = incomingText()
            context.coordinator.isUpdating = true
            if let textStorage = (textView.textContentManager as? NSTextContentStorage)?.textStorage,
               textStorage.string == incomingText.string {
                // Same characters, new styling (the debounced highlight): apply
                // attributes in place so the caret, IME state, and scroll position
                // survive instead of replacing the whole document.
                textStorage.beginEditing()
                incomingText.enumerateAttributes(
                    in: NSRange(location: 0, length: incomingText.length)
                ) { attributes, range, _ in
                    textStorage.setAttributes(attributes, range: range)
                }
                textStorage.endEditing()
            } else {
                let currentSelection = textView.selectedRange()
                textView.attributedText = incomingText
                textView.textSelection = currentSelection.clamped(toLength: incomingText.length)
            }
            resolvedCurrentText = incomingText
            context.coordinator.isUpdating = false
        }
        context.coordinator.isUserEditing = false

        let shouldApplySelection = selection.map { proposedSelection in
            !textView.hasMarkedText() && textView.textSelection != proposedSelection
        } ?? false

        if shouldApplySelection, let selection {
            let textLength = currentText().length
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

        textView.needsLayout = true
        textView.needsDisplay = true
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, selection: $selection)
    }

    @MainActor
    final class Coordinator: @preconcurrency STTextViewDelegate {
        @Binding var text: AttributedString
        @Binding var selection: NSRange?
        var isUpdating = false
        var isUserEditing = false

        init(text: Binding<AttributedString>, selection: Binding<NSRange?>) {
            _text = text
            _selection = selection
        }

        func textViewDidChangeText(_ notification: Notification) {
            guard !isUpdating, let textView = notification.object as? STTextView else {
                return
            }

            isUserEditing = true
            text = AttributedString(textView.attributedText ?? NSAttributedString())
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
