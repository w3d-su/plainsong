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

/// STTextView wrapper with a String-only typing hot path.
///
/// Per-keystroke work must never convert the whole document between
/// String/NSAttributedString/AttributedString — that bridging caused visible lag on
/// 1 MB documents. Plain `String` flows through `text`; styling arrives separately
/// (and rarely) via `styledText` and is applied in place.
struct MarkdownTextView: NSViewRepresentable {
    typealias Coordinator = MarkdownTextViewCoordinator

    @Environment(\.isEnabled) private var isEnabled
    @Binding private var text: String
    @Binding private var selection: NSRange?

    private let styledText: HighlightedText?
    private let showsLineNumbers: Bool
    private let font: NSFont
    private let lineHeightMultiple: CGFloat
    private let scrollProxy: EditorScrollProxy?
    private let commandProxy: EditorCommandProxy?
    private let completionWorkspace: CompletionWorkspace
    private let imageAssetInserter: EditorImageAssetInserter?
    private let imageAssetContextID: String?
    private let isWYSIWYGZeroWidthFoldingEnabled: Bool
    private let onVisibleRangeChange: (NSRange) -> Void

    init(
        text: Binding<String>,
        styledText: HighlightedText?,
        selection: Binding<NSRange?>,
        showsLineNumbers: Bool,
        scrollProxy: EditorScrollProxy? = nil,
        commandProxy: EditorCommandProxy? = nil,
        completionWorkspace: CompletionWorkspace = .empty,
        imageAssetInserter: EditorImageAssetInserter? = nil,
        imageAssetContextID: String? = nil,
        isWYSIWYGZeroWidthFoldingEnabled: Bool = false,
        font: NSFont = MarkdownSyntaxHighlighter.defaultFont,
        lineHeightMultiple: CGFloat = 1.25,
        onVisibleRangeChange: @escaping (NSRange) -> Void = { _ in }
    ) {
        _text = text
        _selection = selection
        self.styledText = styledText
        self.showsLineNumbers = showsLineNumbers
        self.scrollProxy = scrollProxy
        self.commandProxy = commandProxy
        self.completionWorkspace = completionWorkspace
        self.imageAssetInserter = imageAssetInserter
        self.imageAssetContextID = imageAssetContextID
        self.isWYSIWYGZeroWidthFoldingEnabled = isWYSIWYGZeroWidthFoldingEnabled
        self.font = font
        self.lineHeightMultiple = lineHeightMultiple
        self.onVisibleRangeChange = onVisibleRangeChange
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = MarkdownSTTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? MarkdownSTTextView else {
            assertionFailure("Expected MarkdownSTTextView.scrollableTextView() to contain a MarkdownSTTextView")
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
        textView.setWYSIWYGZeroWidthFoldingEnabled(isWYSIWYGZeroWidthFoldingEnabled)

        context.coordinator.isUpdating = true
        textView.text = text
        context.coordinator.isUpdating = false
        context.coordinator.attachScrollProxy(scrollProxy, to: textView)
        context.coordinator.attachCommandProxy(commandProxy, to: textView)
        context.coordinator.updateCompletionWorkspace(completionWorkspace)
        context.coordinator.updateImageAssetInserter(imageAssetInserter)
        context.coordinator.updateImageAssetContextID(imageAssetContextID)
        textView.setWYSIWYGZeroWidthFoldingEnabled(isWYSIWYGZeroWidthFoldingEnabled)
        context.coordinator.attachPasteAndDragHandlers(to: textView)
        context.coordinator.attachVisibleRangeReporter(onVisibleRangeChange, to: textView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MarkdownSTTextView else {
            assertionFailure("Expected MarkdownTextView to update a MarkdownSTTextView-backed scroll view")
            return
        }

        context.coordinator.attachScrollProxy(scrollProxy, to: textView)
        context.coordinator.attachCommandProxy(commandProxy, to: textView)
        context.coordinator.updateCompletionWorkspace(completionWorkspace)
        context.coordinator.updateImageAssetInserter(imageAssetInserter)
        context.coordinator.updateImageAssetContextID(imageAssetContextID)
        context.coordinator.attachPasteAndDragHandlers(to: textView)
        context.coordinator.attachVisibleRangeReporter(onVisibleRangeChange, to: textView)

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
        if textView.font.fontName != font.fontName || textView.font.pointSize != font.pointSize {
            textView.font = font
            textView.gutterView?.font = font
        }
        // No unconditional needsLayout/needsDisplay here: forcing a relayout pass on
        // every SwiftUI update (i.e. every keystroke) is wasted work — text and
        // attribute edits already invalidate exactly what changed.
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        guard let textView = scrollView.documentView as? MarkdownSTTextView else { return }
        coordinator.detachPasteAndDragHandlers(from: textView)
        coordinator.detachCommandProxy(from: textView)
        coordinator.detachScrollProxy()
        coordinator.detachVisibleRangeReporter()
        coordinator.cancelCompletionRequest()
    }

    /// Applies the debounced highlight as an in-place attribute pass: the caret, IME
    /// state, and scroll position survive because the characters never change. Stale
    /// styling (the text moved on) is dropped — a newer revision is already scheduled.
    private func applyStyledTextIfNeeded(to textView: STTextView, coordinator: Coordinator) {
        guard let styledText,
              styledText.revision != coordinator.lastAppliedHighlightRevision,
              !coordinator.isUserEditing,
              !textView.hasMarkedText()
        else {
            return
        }

        coordinator.isUpdating = true
        if Self.applyHighlightedText(styledText, to: textView) {
            coordinator.lastAppliedHighlightRevision = styledText.revision
        }
        coordinator.isUpdating = false
    }

    @MainActor
    @discardableResult
    static func applyHighlightedText(_ styledText: HighlightedText, to textView: STTextView) -> Bool {
        guard
            !textView.hasMarkedText(),
            let textStorage = textStorage(of: textView)
        else {
            return false
        }

        let incoming = NSAttributedString(styledText.text)
        let targetRange = styledText.range.clamped(toLength: textStorage.length)
        guard targetRange.length == incoming.length else {
            return false
        }

        if incoming.length > 0 {
            let currentText = (textStorage.string as NSString).substring(with: targetRange)
            guard currentText == incoming.string else {
                return false
            }
        }

        let selectedRange = textView.selectedRange()
        let clipView = textView.enclosingScrollView?.contentView
        let visibleOrigin = clipView?.bounds.origin
        let undoManager = textView.undoManager
        let shouldRestoreUndoRegistration = undoManager?.isUndoRegistrationEnabled == true
        undoManager?.disableUndoRegistration()
        defer {
            if shouldRestoreUndoRegistration {
                undoManager?.enableUndoRegistration()
            }
            if textView.selectedRange() != selectedRange {
                textView.textSelection = selectedRange.clamped(toLength: textStorage.length)
            }
            if let clipView, let visibleOrigin {
                clipView.scroll(to: visibleOrigin)
                textView.enclosingScrollView?.reflectScrolledClipView(clipView)
            }
        }

        textStorage.beginEditing()
        incoming.enumerateAttributes(
            in: NSRange(location: 0, length: incoming.length)
        ) { attributes, range, _ in
            let destinationRange = NSRange(
                location: targetRange.location + range.location,
                length: range.length
            )
            textStorage.setAttributes(attributes, range: destinationRange)
        }
        textStorage.endEditing()
        if styledText.foldPlan != nil,
           let textRange = NSTextRange(targetRange, in: textView.textContentManager) {
            textView.textLayoutManager.invalidateLayout(for: textRange)
        }
        textView.needsDisplay = true
        return true
    }

    @MainActor
    static func textStorage(of textView: STTextView) -> NSTextStorage? {
        (textView.textContentManager as? NSTextContentStorage)?.textStorage
    }

    @MainActor
    static func visibleTextRange(of textView: STTextView) -> NSRange? {
        guard let textStorage = textStorage(of: textView) else {
            return nil
        }

        let textLength = textStorage.length
        guard textLength > 0 else {
            return NSRange(location: 0, length: 0)
        }

        let layoutManager = textView.textLayoutManager
        let contentManager = textView.textContentManager
        guard let viewportRange = layoutManager.textViewportLayoutController.viewportRange else {
            return textView.selectedRange().clamped(toLength: textLength)
        }

        let documentStart = contentManager.documentRange.location
        let start = contentManager.offset(from: documentStart, to: viewportRange.location)
        let end = contentManager.offset(from: documentStart, to: viewportRange.endLocation)
        guard start != NSNotFound, end != NSNotFound else {
            return textView.selectedRange().clamped(toLength: textLength)
        }

        return NSRange(
            location: min(start, end),
            length: max(0, end - start)
        ).clamped(toLength: textLength)
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
}
