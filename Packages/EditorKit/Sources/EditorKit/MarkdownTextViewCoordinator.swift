import AppKit
import MarkdownCore
import STTextView
import SwiftUI

@MainActor
struct EditorDocumentTransitionCandidate {
    let generation: UInt64
    let sourceText: String
    let requestedSelection: NSRange?
    fileprivate let text: Binding<String>
    fileprivate let selection: Binding<NSRange?>
    fileprivate let documentIdentity: EditorDocumentIdentity?
    fileprivate let documentBinding: EditorDocumentBindingRegistration?
}

struct EditorDocumentInstallation: Equatable {
    let generation: UInt64
}

@MainActor
private struct EditorDocumentBindingRegistration {
    let id: EditorDocumentBindingID
    let lifecycle: (EditorDocumentBindingLifecycleEvent) -> Void
}

@MainActor
private struct EditorDocumentBindingTransition {
    let revoked: EditorDocumentBindingRegistration?
    let installed: EditorDocumentBindingRegistration?

    func notify() {
        if let installed {
            installed.lifecycle(.installed(installed.id))
        }
        if let revoked {
            revoked.lifecycle(.revoked(revoked.id))
        }
    }
}

@MainActor
private struct EditorInstalledDocumentState {
    private var textBinding: Binding<String>
    private var selectionBinding: Binding<NSRange?>
    private var documentBinding: EditorDocumentBindingRegistration?
    private(set) var identity: EditorDocumentIdentity?
    private(set) var isInstalled = false
    private var nextCandidateGeneration: UInt64 = 0
    private(set) var preparedCandidateGeneration: UInt64?
    private(set) var installedCandidateGeneration: UInt64?

    init(text: Binding<String>, selection: Binding<NSRange?>) {
        textBinding = text
        selectionBinding = selection
    }

    var text: String {
        get { textBinding.wrappedValue }
        set { textBinding.wrappedValue = newValue }
    }

    var selection: NSRange? {
        get { selectionBinding.wrappedValue }
        set { selectionBinding.wrappedValue = newValue }
    }

    var isPreparedCandidateInstalled: Bool {
        isInstalled && preparedCandidateGeneration == installedCandidateGeneration
    }

    mutating func prepare(
        text: Binding<String>,
        selection: Binding<NSRange?>,
        documentIdentity: EditorDocumentIdentity?,
        documentBindingID: EditorDocumentBindingID?,
        onDocumentBindingLifecycle: ((EditorDocumentBindingLifecycleEvent) -> Void)?
    ) -> EditorDocumentTransitionCandidate {
        nextCandidateGeneration += 1
        preparedCandidateGeneration = nextCandidateGeneration

        // Before the first installation there is no live document to protect. Once
        // installed, bindings change only in `install`, after exact text validation.
        if !isInstalled {
            textBinding = text
            selectionBinding = selection
        }

        let documentBinding: EditorDocumentBindingRegistration? = if let documentBindingID,
                                                                     let onDocumentBindingLifecycle
        {
            EditorDocumentBindingRegistration(
                id: documentBindingID,
                lifecycle: onDocumentBindingLifecycle
            )
        } else {
            nil
        }

        return EditorDocumentTransitionCandidate(
            generation: nextCandidateGeneration,
            sourceText: text.wrappedValue,
            requestedSelection: selection.wrappedValue,
            text: text,
            selection: selection,
            documentIdentity: documentIdentity,
            documentBinding: documentBinding
        )
    }

    mutating func install(
        _ candidate: EditorDocumentTransitionCandidate
    ) -> (EditorDocumentInstallation, EditorDocumentBindingTransition) {
        let previousBinding = documentBinding
        textBinding = candidate.text
        selectionBinding = candidate.selection
        identity = candidate.documentIdentity
        documentBinding = candidate.documentBinding
        isInstalled = true
        installedCandidateGeneration = candidate.generation
        let bindingChanged = previousBinding?.id != candidate.documentBinding?.id
        return (
            EditorDocumentInstallation(generation: candidate.generation),
            EditorDocumentBindingTransition(
                revoked: bindingChanged ? previousBinding : nil,
                installed: bindingChanged ? candidate.documentBinding : nil
            )
        )
    }

    mutating func revokeDocumentBinding() -> EditorDocumentBindingRegistration? {
        defer { documentBinding = nil }
        return documentBinding
    }
}

@MainActor
final class MarkdownTextViewCoordinator: @preconcurrency STTextViewDelegate {
    private var installedDocument: EditorInstalledDocumentState
    var text: String {
        get { installedDocument.text }
        set { installedDocument.text = newValue }
    }

    var selection: NSRange? {
        get { installedDocument.selection }
        set { installedDocument.selection = newValue }
    }

    var isUpdating = false
    var isUserEditing = false
    var lastAppliedHighlightRevision: Int?
    var currentDocumentIdentity: EditorDocumentIdentity? {
        installedDocument.identity
    }

    var navigationState = EditorNavigationStateMachine()
    var navigationRetryTask: Task<Void, Never>?
    var navigationInputDeferralTask: Task<Void, Never>?
    var isApplyingNavigation = false
    private(set) var lastHandledFocusRequestID: Int?
    private(set) var pendingFocusRequestID: Int?
    private weak var pendingFocusTextView: STTextView?
    private var focusRetryTask: Task<Void, Never>?
    private var scrollProxy: EditorScrollProxy?
    private var commandProxy: EditorCommandProxy?
    private let editingBehaviorGuard = EditingBehaviorGuard()
    private var completionWorkspace: CompletionWorkspace = .empty
    private var imageAssetInserter: EditorImageAssetInserter?
    private var imageAssetContextID: String?
    let imageThumbnailPresentationController = WYSIWYGImagePresentationController()
    private var recentCompletionIDs: [String] = []
    private var completionRequestID = 0
    private var completionTask: Task<[Completion], Never>?
    private weak var visibleRangeTextView: STTextView?
    private var visibleRangeObserver: CoordinatorNotificationObserver?
    private var visibleRangeChangeHandler: ((NSRange) -> Void)?
    private var lastVisibleTextRange: NSRange?

    init(text: Binding<String>, selection: Binding<NSRange?>) {
        installedDocument = EditorInstalledDocumentState(text: text, selection: selection)
    }

    func prepareDocumentTransition(
        text: Binding<String>,
        selection: Binding<NSRange?>,
        documentIdentity: EditorDocumentIdentity?,
        documentBindingID: EditorDocumentBindingID? = nil,
        onDocumentBindingLifecycle: ((EditorDocumentBindingLifecycleEvent) -> Void)? = nil,
        navigationCommand: EditorNavigationCommand?,
        in textView: STTextView
    ) -> EditorDocumentTransitionCandidate {
        observeNavigationCommand(navigationCommand)

        let candidate = installedDocument.prepare(
            text: text,
            selection: selection,
            documentIdentity: documentIdentity,
            documentBindingID: documentBindingID,
            onDocumentBindingLifecycle: onDocumentBindingLifecycle
        )

        guard installedDocument.isInstalled,
              !textView.hasMarkedText(),
              !MarkdownTextView.plainTextMatches(textView, candidate.sourceText)
        else {
            return candidate
        }

        // A mismatching candidate cannot be the live installed document. Allow the
        // normal external-text update even when both optional identities are nil.
        isUserEditing = false
        return candidate
    }

    @discardableResult
    func finishDocumentTransition(
        _ candidate: EditorDocumentTransitionCandidate,
        in textView: STTextView
    ) -> EditorDocumentInstallation? {
        guard candidate.generation == installedDocument.preparedCandidateGeneration,
              !textView.hasMarkedText(),
              MarkdownTextView.plainTextMatches(textView, candidate.sourceText)
        else {
            return nil
        }

        let (installation, bindingTransition) = installedDocument.install(candidate)
        bindingTransition.notify()
        cancelPendingNavigationTasks()
        return installation
    }

    func revokeInstalledDocumentBinding() {
        guard let registration = installedDocument.revokeDocumentBinding() else { return }
        registration.lifecycle(.revoked(registration.id))
    }

    var isPreparedDocumentInstalled: Bool {
        installedDocument.isPreparedCandidateInstalled
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

    func attachVisibleRangeReporter(_ handler: @escaping (NSRange) -> Void, to textView: STTextView) {
        visibleRangeChangeHandler = handler

        if visibleRangeTextView !== textView {
            visibleRangeObserver = nil
            visibleRangeTextView = textView
            lastVisibleTextRange = nil

            if let clipView = textView.enclosingScrollView?.contentView {
                clipView.postsBoundsChangedNotifications = true
                visibleRangeObserver = CoordinatorNotificationObserver(NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: clipView,
                    queue: .main
                ) { [weak self, weak textView] _ in
                    Task { @MainActor [weak self, weak textView] in
                        guard let textView else { return }
                        self?.reportVisibleRangeIfNeeded(in: textView)
                    }
                })
            }
        }

        reportVisibleRangeIfNeeded(in: textView)
    }

    func detachVisibleRangeReporter() {
        visibleRangeObserver = nil
        visibleRangeTextView = nil
        visibleRangeChangeHandler = nil
        lastVisibleTextRange = nil
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

    func updateCompletionWorkspace(_ workspace: CompletionWorkspace) {
        completionWorkspace = workspace
    }

    func updateImageAssetInserter(_ inserter: EditorImageAssetInserter?) {
        imageAssetInserter = inserter
    }

    func updateImageAssetContextID(_ contextID: String?) {
        imageAssetContextID = contextID
    }
}

extension MarkdownTextViewCoordinator {
    func attachFocusHandler(to textView: MarkdownSTTextView) {
        textView.windowAttachmentHandler = { [weak self, weak textView] _ in
            guard let self, let textView else { return }
            focusPendingRequestIfPossible(in: textView)
            applyPendingNavigationIfPossible(in: textView)
        }
    }

    func detachFocusHandler(from textView: MarkdownSTTextView) {
        textView.windowAttachmentHandler = nil
        if pendingFocusTextView === textView {
            cancelPendingFocusRequest()
        }
        cancelPendingNavigationTasks()
    }

    func cancelPendingFocusRequest() {
        focusRetryTask?.cancel()
        focusRetryTask = nil
        pendingFocusRequestID = nil
        pendingFocusTextView = nil
    }

    func focusIfNeeded(_ requestID: Int, textView: STTextView) {
        guard requestID > 0,
              lastHandledFocusRequestID != requestID
        else {
            return
        }

        if focus(requestID, textView: textView) {
            cancelPendingFocusRequest()
            return
        }

        pendingFocusRequestID = requestID
        pendingFocusTextView = textView
        scheduleFocusRetry(for: requestID, textView: textView)
    }

    private func scheduleFocusRetry(for requestID: Int, textView: STTextView) {
        focusRetryTask?.cancel()
        focusRetryTask = Task { @MainActor [weak self, weak textView] in
            for _ in 0 ..< 60 {
                do {
                    try await Task.sleep(nanoseconds: 50_000_000)
                } catch {
                    return
                }

                guard let self, let textView else {
                    return
                }
                if pendingFocusRequestID != requestID {
                    return
                }
                if focusPendingRequestIfPossible(in: textView) {
                    return
                }
            }
        }
    }

    @discardableResult
    private func focusPendingRequestIfPossible(in textView: STTextView) -> Bool {
        guard let requestID = pendingFocusRequestID,
              pendingFocusTextView === textView
        else {
            return false
        }

        if focus(requestID, textView: textView) {
            cancelPendingFocusRequest()
            return true
        }

        return false
    }

    @discardableResult
    private func focus(_ requestID: Int, textView: STTextView) -> Bool {
        guard textView.acceptsFirstResponder,
              let window = textView.window
        else {
            return false
        }

        ensureInsertionPointIfNeeded(in: textView)

        guard window.firstResponder !== textView else {
            lastHandledFocusRequestID = requestID
            return true
        }

        guard window.makeFirstResponder(textView) else {
            return false
        }

        lastHandledFocusRequestID = requestID
        return true
    }

    private func ensureInsertionPointIfNeeded(in textView: STTextView) {
        guard textView.selectedRange().location == NSNotFound else {
            return
        }

        textView.textSelection = NSRange(location: 0, length: 0)
    }

    func attachPasteAndDragHandlers(to textView: MarkdownSTTextView) {
        textView.pasteHandler = { [weak self, weak textView] _, pasteboard in
            guard let self, let textView else { return false }
            return handlePaste(in: textView, pasteboard: pasteboard)
        }

        if imageAssetInserter == nil {
            textView.imageFileDropHandler = nil
        } else {
            textView.imageFileDropHandler = { [weak self, weak textView] _, urls in
                guard let self, let textView else { return false }
                return handleImageFileDrop(in: textView, urls: urls)
            }
        }
    }

    func detachPasteAndDragHandlers(from textView: MarkdownSTTextView) {
        textView.pasteHandler = nil
        textView.imageFileDropHandler = nil
    }

    func cancelCompletionRequest() {
        completionRequestID += 1
        completionTask?.cancel()
        completionTask = nil
    }

    private func performCommand(_ command: MarkdownEditCommand, in textView: STTextView) {
        EditingBehaviorsSupport.applyCommand(
            command,
            to: textView,
            editingGuard: editingBehaviorGuard
        )
    }

    func textViewWillChangeText(_: Notification) {
        guard !isUpdating else {
            return
        }

        isUserEditing = true
    }

    func textViewDidChangeText(_ notification: Notification) {
        guard !isUpdating, let textView = notification.object as? STTextView else {
            return
        }

        isUserEditing = true
        syncTextFromTextViewIfNeeded(textView)
        if let textView = textView as? MarkdownSTTextView {
            imageThumbnailPresentationController.documentTextDidChange(in: textView)
        }
        reportVisibleRangeIfNeeded(in: textView)
        schedulePendingNavigationAfterInput(in: textView)
    }

    func textView(
        _ textView: STTextView,
        shouldChangeTextIn affectedCharRange: NSTextRange,
        replacementString: String?
    ) -> Bool {
        if !isUpdating {
            isUserEditing = true
        }

        let fileKind = commandProxy?.currentFileKind() ?? .markdown
        let selection = NSRange(affectedCharRange, in: textView.textContentManager)
        let shouldTriggerCompletion = replacementString.map {
            EditorCompletionSupport.shouldTriggerCompletion(
                replacementString: $0,
                emojiShortcodePrefixBeforeChange: EditorCompletionSupport.emojiShortcodePrefixBeforeSelection(
                    in: textView,
                    selection: selection
                ),
                fileKind: fileKind
            )
        } ?? false

        let shouldAllowNativeInput = EditingBehaviorsSupport.handleProposedChange(
            in: textView,
            affectedRange: affectedCharRange,
            replacementString: replacementString,
            fileKind: fileKind,
            editingGuard: editingBehaviorGuard
        )

        if shouldTriggerCompletion {
            requestCompletion(afterApplyingChangeIn: textView)
        }

        return shouldAllowNativeInput
    }

    func textView(
        _ textView: STTextView,
        didChangeTextIn _: NSTextRange,
        replacementString _: String
    ) {
        guard !isUpdating else {
            return
        }

        isUserEditing = true
        syncTextFromTextViewIfNeeded(textView)
        if let textView = textView as? MarkdownSTTextView {
            imageThumbnailPresentationController.documentTextDidChange(in: textView)
        }
        schedulePendingNavigationAfterInput(in: textView)
    }

    func textView(
        _ textView: STTextView,
        completionItemsAtLocation _: any NSTextLocation
    ) async -> [any STCompletionItem]? {
        guard !textView.hasMarkedText() else { return nil }
        let text = MarkdownTextView.textStorage(of: textView)?.string ?? textView.text ?? ""
        let cursor = textView.selectedRange().location
        var workspace = completionWorkspace
        workspace.recentlyUsedCompletionIDs = recentCompletionIDs
        completionRequestID += 1
        let requestID = completionRequestID
        completionTask?.cancel()

        let task = Task.detached(priority: .userInitiated) {
            CompletionEngine().complete(text: text, cursor: cursor, workspace: workspace)
        }
        completionTask = task
        let completions = await task.value

        if completionRequestID == requestID {
            completionTask = nil
        }

        guard !task.isCancelled,
              completionRequestID == requestID,
              !completions.isEmpty
        else {
            return nil
        }
        return completions.map { MarkdownCompletionItem(completion: $0) }
    }

    func textView(_ textView: STTextView, insertCompletionItem item: any STCompletionItem) {
        guard let item = item as? MarkdownCompletionItem else { return }
        recentCompletionIDs = EditorCompletionSupport.recentCompletionIDs(
            selecting: item.id,
            existing: recentCompletionIDs
        )
        EditorCompletionSupport.insert(item.completion, into: textView, editingGuard: editingBehaviorGuard)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !isUpdating, let textView = notification.object as? STTextView else {
            return
        }

        if syncTextFromTextViewIfNeeded(textView) {
            isUserEditing = true
            if let textView = textView as? MarkdownSTTextView {
                imageThumbnailPresentationController.documentTextDidChange(in: textView)
            }
        }
        selection = textView.selectedRange()
        scrollProxy?.emitVisibleLine(containingUTF16Offset: textView.selectedRange().location, in: textView)
        reportVisibleRangeIfNeeded(in: textView)
        schedulePendingNavigationAfterInput(in: textView)
    }

    @discardableResult
    private func syncTextFromTextViewIfNeeded(_ textView: STTextView) -> Bool {
        guard !shouldDeferTextSync(from: textView) else {
            return false
        }

        // `textStorage.string` is a lazily bridged ("foreign") String backed by
        // CFStorage. One eager transcode here makes later operations native-fast.
        var newText = MarkdownTextView.textStorage(of: textView)?.string ?? textView.text ?? ""
        guard !ExactUTF16Text.matches(newText, text) else {
            return false
        }
        newText.makeContiguousUTF8()
        text = newText
        return true
    }

    private func shouldDeferTextSync(from textView: STTextView) -> Bool {
        if let textView = textView as? MarkdownSTTextView,
           textView.isSuppressingIntermediateMarkedTextRemoval
        {
            return true
        }

        return textView.hasMarkedText()
    }

    private func requestCompletion(afterApplyingChangeIn textView: STTextView) {
        Task { @MainActor [weak textView] in
            await Task.yield()
            guard let textView, !textView.hasMarkedText() else { return }
            textView.complete(nil)
        }
    }

    private func reportVisibleRangeIfNeeded(in textView: STTextView) {
        guard let visibleRange = MarkdownTextView.visibleTextRange(of: textView),
              visibleRange != lastVisibleTextRange
        else {
            return
        }

        lastVisibleTextRange = visibleRange
        scrollProxy?.emitVisibleLine(containingUTF16Offset: visibleRange.location, in: textView)
        visibleRangeChangeHandler?(visibleRange)
    }

    private func handlePaste(in textView: MarkdownSTTextView, pasteboard: NSPasteboard) -> Bool {
        guard MarkdownEditing.shouldHandleBehavior(hasMarkedText: textView.hasMarkedText()) else {
            return false
        }

        if applyURLSmartPaste(in: textView, pasteboard: pasteboard) {
            return true
        }

        guard imageAssetInserter != nil else { return false }
        let assets = MarkdownSTTextView.imageAssets(from: pasteboard)
        guard !assets.isEmpty else { return false }

        insertImageAssets(assets, into: textView, replacementRange: textView.selectedRange())
        return true
    }

    private func applyURLSmartPaste(in textView: MarkdownSTTextView, pasteboard: NSPasteboard) -> Bool {
        guard let url = pasteboard.string(forType: .string),
              SmartPaste.isSingleURL(url)
        else {
            return false
        }

        let text = MarkdownTextView.textStorage(of: textView)?.string ?? textView.text ?? ""
        let textLength = (text as NSString).length
        let selectionRange = textView.selectedRange().clamped(toLength: textLength)
        guard selectionRange.length > 0 else { return false }

        let selectedText = (text as NSString).substring(with: selectionRange)
        guard let replacement = SmartPaste.linkReplacement(selection: selectedText, url: url) else {
            return false
        }

        let newSelection = NSRange(
            location: selectionRange.location + (replacement as NSString).length,
            length: 0
        )
        EditingBehaviorsSupport.applyReplacement(
            replacement,
            replacementRange: selectionRange,
            newSelection: newSelection,
            to: textView,
            editingGuard: editingBehaviorGuard
        )
        return true
    }

    private func handleImageFileDrop(in textView: MarkdownSTTextView, urls: [URL]) -> Bool {
        guard imageAssetInserter != nil,
              MarkdownEditing.shouldHandleBehavior(hasMarkedText: textView.hasMarkedText()),
              !urls.isEmpty
        else {
            return false
        }

        insertImageAssets(urls.map(EditorImageAsset.file), into: textView, replacementRange: textView.selectedRange())
        return true
    }

    private func insertImageAssets(
        _ assets: [EditorImageAsset],
        into textView: MarkdownSTTextView,
        replacementRange: NSRange
    ) {
        guard let imageAssetInserter else { return }
        let capturedText = MarkdownTextView.textStorage(of: textView)?.string ?? textView.text ?? ""
        let capturedRange = replacementRange.clamped(toLength: (capturedText as NSString).length)
        let capturedContextID = imageAssetContextID

        Task { @MainActor [weak self, weak textView] in
            guard let self, let textView else { return }
            let relativePaths = await imageAssetInserter(assets)
            guard !relativePaths.isEmpty,
                  imageAssetContextID == capturedContextID,
                  MarkdownEditing.shouldHandleBehavior(hasMarkedText: textView.hasMarkedText())
            else {
                return
            }

            let insertion = relativePaths
                .map { SmartPaste.imageInsertion(relativePath: $0) }
                .joined(separator: "\n")
            let currentText = MarkdownTextView.textStorage(of: textView)?.string ?? textView.text ?? ""
            guard currentText == capturedText else {
                return
            }
            let replacementRange = capturedRange.clamped(toLength: (currentText as NSString).length)
            let newSelection = NSRange(
                location: replacementRange.location + (insertion as NSString).length,
                length: 0
            )
            EditingBehaviorsSupport.applyReplacement(
                insertion,
                replacementRange: replacementRange,
                newSelection: newSelection,
                to: textView,
                editingGuard: editingBehaviorGuard
            )
        }
    }
}

private final class CoordinatorNotificationObserver {
    private let token: NSObjectProtocol

    init(_ token: NSObjectProtocol) {
        self.token = token
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}
