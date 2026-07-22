import AppKit
import MarkdownCore
import STTextView
import SwiftUI

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
    private let focusRequestID: Int
    private let documentIdentity: EditorDocumentIdentity?
    private let documentBindingID: EditorDocumentBindingID?
    private let onDocumentBindingLifecycle: ((EditorDocumentBindingLifecycleEvent) -> Void)?
    private let documentSourceContract: EditorDocumentSourceContract?
    private let navigationCommand: EditorNavigationCommand?
    private let font: NSFont
    private let lineHeightMultiple: CGFloat
    private let scrollProxy: EditorScrollProxy?
    private let commandProxy: EditorCommandProxy?
    private let completionWorkspace: CompletionWorkspace
    private let imageAssetInserter: EditorImageAssetInserter?
    private let imageAssetContextID: String?
    private let isWYSIWYGZeroWidthFoldingEnabled: Bool
    private let imageThumbnailPresentationConfiguration: EditorImageThumbnailConfiguration?
    private let onWYSIWYGMechanismFailure: ((String) -> Void)?
    private let onVisibleRangeChange: (NSRange) -> Void

    init(
        text: Binding<String>,
        styledText: HighlightedText?,
        selection: Binding<NSRange?>,
        showsLineNumbers: Bool,
        focusRequestID: Int = 0,
        documentIdentity: EditorDocumentIdentity? = nil,
        documentBindingID: EditorDocumentBindingID? = nil,
        onDocumentBindingLifecycle: ((EditorDocumentBindingLifecycleEvent) -> Void)? = nil,
        documentSourceContract: EditorDocumentSourceContract? = nil,
        navigationCommand: EditorNavigationCommand? = nil,
        scrollProxy: EditorScrollProxy? = nil,
        commandProxy: EditorCommandProxy? = nil,
        completionWorkspace: CompletionWorkspace = .empty,
        imageAssetInserter: EditorImageAssetInserter? = nil,
        imageAssetContextID: String? = nil,
        isWYSIWYGZeroWidthFoldingEnabled: Bool = false,
        imageThumbnailPresentationConfiguration: EditorImageThumbnailConfiguration? = nil,
        onWYSIWYGMechanismFailure: ((String) -> Void)? = nil,
        font: NSFont = MarkdownSyntaxHighlighter.defaultFont,
        lineHeightMultiple: CGFloat = 1.25,
        onVisibleRangeChange: @escaping (NSRange) -> Void = { _ in }
    ) {
        _text = text
        _selection = selection
        self.styledText = styledText
        self.showsLineNumbers = showsLineNumbers
        self.focusRequestID = focusRequestID
        self.documentIdentity = documentIdentity
        self.documentBindingID = documentBindingID
        self.onDocumentBindingLifecycle = onDocumentBindingLifecycle
        self.documentSourceContract = documentSourceContract
        self.navigationCommand = navigationCommand
        self.scrollProxy = scrollProxy
        self.commandProxy = commandProxy
        self.completionWorkspace = completionWorkspace
        self.imageAssetInserter = imageAssetInserter
        self.imageAssetContextID = imageAssetContextID
        self.isWYSIWYGZeroWidthFoldingEnabled = isWYSIWYGZeroWidthFoldingEnabled
        self.imageThumbnailPresentationConfiguration = imageThumbnailPresentationConfiguration
        self.onWYSIWYGMechanismFailure = onWYSIWYGMechanismFailure
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
        #if DEBUG
            textView.setAccessibilityIdentifier("plainsong.debug.editor.textView")
        #endif

        context.coordinator.isUpdating = true
        textView.text = text
        context.coordinator.isUpdating = false
        let candidate = prepareCoordinatorInputs(context.coordinator, for: textView)
        let installation = context.coordinator.finishDocumentTransition(candidate, in: textView)
        context.coordinator.attachFocusHandler(to: textView)
        if installation != nil {
            // Keep initial construction behavior distinct from representable updates:
            // deferred retries use the update completion path below, while first render
            // must not introduce a new styling or selection pass.
            updateNonDocumentCoordinatorInputs(context.coordinator, for: textView)
            applyWYSIWYGMechanismState(to: textView)
            updateImageThumbnailConfiguration(context.coordinator, for: textView)
            context.coordinator.attachPasteAndDragHandlers(to: textView)
            context.coordinator.attachVisibleRangeReporter(onVisibleRangeChange, to: textView)
            context.coordinator.focusIfNeeded(focusRequestID, textView: textView)
            context.coordinator.applyPendingNavigationIfPossible(in: textView)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        updateRepresentedTextView(scrollView, coordinator: context.coordinator)
    }

    /// Shared implementation kept internal so coordinator-reuse regressions exercise
    /// the same ordering as `NSViewRepresentable.updateNSView`.
    func updateRepresentedTextView(
        _ scrollView: NSScrollView,
        coordinator: Coordinator
    ) {
        guard let textView = scrollView.documentView as? MarkdownSTTextView else {
            assertionFailure("Expected MarkdownTextView to update a MarkdownSTTextView-backed scroll view")
            return
        }

        let candidate = prepareCoordinatorInputs(coordinator, for: textView)
        coordinator.attachFocusHandler(to: textView)

        applyIncomingTextIfNeeded(candidate, to: textView, coordinator: coordinator)

        let installation = coordinator.finishDocumentTransition(candidate, in: textView)

        if installation != nil {
            completeDocumentInstallation(
                candidate,
                in: textView,
                coordinator: coordinator
            )
        }
        coordinator.isUserEditing = false
        // No unconditional needsLayout/needsDisplay here: forcing a relayout pass on
        // every SwiftUI update (i.e. every keystroke) is wasted work — text and
        // attribute edits already invalidate exactly what changed.
    }

    private func applyIncomingTextIfNeeded(
        _ candidate: EditorDocumentTransitionCandidate,
        to textView: MarkdownSTTextView,
        coordinator: Coordinator
    ) {
        guard !coordinator.canProveCurrentInstalledSource(for: candidate),
              !coordinator.hasPendingWriterLease,
              !coordinator.isUserEditing,
              !textView.hasMarkedText()
        else {
            return
        }

        guard !coordinator.nativeTextMatches(
            textView,
            candidate.sourceText,
            recordingFor: candidate
        ) else {
            return
        }

        coordinator.isUpdating = true
        let currentSelection = textView.selectedRange()
        textView.text = candidate.sourceText
        textView.textSelection = currentSelection.clamped(
            toLength: (candidate.sourceText as NSString).length
        )
        coordinator.isUpdating = false
        coordinator.notePreparedNativeSource(candidate)
    }

    private func prepareCoordinatorInputs(
        _ coordinator: Coordinator,
        for textView: MarkdownSTTextView
    ) -> EditorDocumentTransitionCandidate {
        coordinator.setDeferredDocumentTransitionInstallationHandler { [self] coordinator, candidate, textView in
            completeDocumentInstallation(
                candidate,
                in: textView,
                coordinator: coordinator
            )
        }
        return coordinator.prepareDocumentTransition(
            text: $text,
            selection: $selection,
            documentIdentity: documentIdentity,
            documentBindingID: documentBindingID,
            onDocumentBindingLifecycle: onDocumentBindingLifecycle,
            documentSourceContract: documentSourceContract,
            navigationCommand: navigationCommand,
            in: textView
        )
    }

    private func completeDocumentInstallation(
        _ candidate: EditorDocumentTransitionCandidate,
        in textView: MarkdownSTTextView,
        coordinator: Coordinator
    ) {
        updateNonDocumentCoordinatorInputs(coordinator, for: textView)
        coordinator.attachPasteAndDragHandlers(to: textView)
        coordinator.attachVisibleRangeReporter(onVisibleRangeChange, to: textView)
        applyWYSIWYGMechanismState(to: textView)
        updateImageThumbnailConfiguration(coordinator, for: textView)
        coordinator.focusIfNeeded(focusRequestID, textView: textView)
        let didApplyStyledText = applyStyledTextIfNeeded(to: textView, coordinator: coordinator)
        if didApplyStyledText, let styledText {
            // Markers are preserved across highlight setAttributes; only force a rewrite
            // when the plan/outcomes change (handled inside the presentation controller).
            coordinator.applyImageThumbnailPresentation(
                foldPlan: styledText.foldPlan,
                in: textView,
                forceReapply: false
            )
        }

        let shouldApplySelection = candidate.requestedSelection.map { proposedSelection in
            !textView.hasMarkedText()
                && textView.textSelection != proposedSelection
        } ?? false

        if shouldApplySelection, let selection = candidate.requestedSelection {
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
        coordinator.applyPendingNavigationIfPossible(in: textView)
        coordinator.isUserEditing = false
    }

    private func updateNonDocumentCoordinatorInputs(_ coordinator: Coordinator, for textView: MarkdownSTTextView) {
        coordinator.attachScrollProxy(scrollProxy, to: textView)
        coordinator.attachCommandProxy(commandProxy, to: textView)
        coordinator.updateCompletionWorkspace(completionWorkspace)
        coordinator.updateImageAssetInserter(imageAssetInserter)
        coordinator.updateImageAssetContextID(imageAssetContextID)
    }

    private func applyWYSIWYGMechanismState(to textView: MarkdownSTTextView) {
        let didApply = textView.setWYSIWYGZeroWidthFoldingEnabled(isWYSIWYGZeroWidthFoldingEnabled)
        guard isWYSIWYGZeroWidthFoldingEnabled, !didApply else {
            return
        }

        onWYSIWYGMechanismFailure?("TextKit 2 content storage was unavailable for WYSIWYG folding")
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        guard let textView = scrollView.documentView as? MarkdownSTTextView else { return }
        coordinator.detachFocusHandler(from: textView)
        coordinator.detachPasteAndDragHandlers(from: textView)
        coordinator.detachCommandProxy(from: textView)
        coordinator.detachScrollProxy()
        coordinator.detachVisibleRangeReporter()
        coordinator.cancelCompletionRequest()
        coordinator.cancelPendingNavigationTasks()
        coordinator.detachDeferredDocumentTransitionInstallationHandler()
        coordinator.revokeInstalledDocumentBinding()
        coordinator.detachImageThumbnailPresentation(from: textView)
        textView.textDelegate = nil
    }

    /// Applies the debounced highlight as an in-place attribute pass: the caret, IME
    /// state, and scroll position survive because the characters never change. Stale
    /// styling (the text moved on) is dropped — a newer revision is already scheduled.
    @discardableResult
    private func applyStyledTextIfNeeded(to textView: STTextView, coordinator: Coordinator) -> Bool {
        guard let styledText,
              styledText.revision != coordinator.lastAppliedHighlightRevision,
              !coordinator.isUserEditing,
              !textView.hasMarkedText()
        else {
            return false
        }

        coordinator.isUpdating = true
        let didApply = Self.applyHighlightedText(styledText, to: textView)
        if didApply {
            coordinator.lastAppliedHighlightRevision = styledText.revision
        }
        coordinator.isUpdating = false
        return didApply
    }

    @MainActor
    @discardableResult
    static func applyHighlightedText(_ styledText: HighlightedText, to textView: STTextView) -> Bool {
        applyHighlightedTextPreservingImageMarkers(styledText, to: textView)
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
        return ExactUTF16Text.matches(textStorage.string, candidate)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, selection: $selection)
    }
}

private extension MarkdownTextView {
    func updateImageThumbnailConfiguration(
        _ coordinator: Coordinator,
        for textView: MarkdownSTTextView
    ) {
        coordinator.updateImageThumbnailPresentationConfiguration(
            imageThumbnailPresentationConfiguration,
            documentIdentity: documentIdentity,
            isPresentationEnabled: isWYSIWYGZeroWidthFoldingEnabled,
            in: textView
        )
    }
}
