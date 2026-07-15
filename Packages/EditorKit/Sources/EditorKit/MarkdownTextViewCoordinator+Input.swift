import AppKit
import MarkdownCore
import STTextView

@MainActor
extension MarkdownTextViewCoordinator {
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

    func performCommand(_ command: MarkdownEditCommand, in textView: STTextView) {
        EditingBehaviorsSupport.applyCommand(
            command,
            to: textView,
            editingGuard: editingBehaviorGuard
        )
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

    func requestCompletion(afterApplyingChangeIn textView: STTextView) {
        Task { @MainActor [weak textView] in
            await Task.yield()
            guard let textView, !textView.hasMarkedText() else { return }
            textView.complete(nil)
        }
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
