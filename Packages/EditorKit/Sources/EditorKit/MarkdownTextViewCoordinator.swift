import AppKit
import MarkdownCore
import STTextView
import SwiftUI

@MainActor
final class MarkdownTextViewCoordinator: @preconcurrency STTextViewDelegate {
    @Binding var text: String
    @Binding var selection: NSRange?
    var isUpdating = false
    var isUserEditing = false
    var lastAppliedHighlightRevision: Int?
    private var scrollProxy: EditorScrollProxy?
    private var commandProxy: EditorCommandProxy?
    private let editingBehaviorGuard = EditingBehaviorGuard()
    private var completionWorkspace: CompletionWorkspace = .empty
    private var imageAssetInserter: EditorImageAssetInserter?
    private var imageAssetContextID: String?
    private var recentCompletionIDs: [String] = []
    private var completionRequestID = 0
    private var completionTask: Task<[Completion], Never>?
    private weak var visibleRangeTextView: STTextView?
    private var visibleRangeObserver: CoordinatorNotificationObserver?
    private var visibleRangeChangeHandler: ((NSRange) -> Void)?
    private var lastVisibleTextRange: NSRange?

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

    func textViewDidChangeText(_ notification: Notification) {
        guard !isUpdating, let textView = notification.object as? STTextView else {
            return
        }

        isUserEditing = true
        // `textStorage.string` is a lazily bridged ("foreign") String backed by
        // CFStorage. One eager transcode here makes later operations native-fast.
        var newText = MarkdownTextView.textStorage(of: textView)?.string ?? textView.text ?? ""
        newText.makeContiguousUTF8()
        text = newText
        reportVisibleRangeIfNeeded(in: textView)
    }

    func textView(
        _ textView: STTextView,
        shouldChangeTextIn affectedCharRange: NSTextRange,
        replacementString: String?
    ) -> Bool {
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

        selection = textView.selectedRange()
        scrollProxy?.emitVisibleLine(containingUTF16Offset: textView.selectedRange().location, in: textView)
        reportVisibleRangeIfNeeded(in: textView)
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
