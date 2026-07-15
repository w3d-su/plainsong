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
        guard let proposal = EditingBehaviorsSupport.proposedCommand(
            command,
            in: textView,
            editingGuard: editingBehaviorGuard
        ) else {
            return
        }

        switch proposal {
        case .allowNativeInput:
            return
        case .selectionOnly:
            _ = EditingBehaviorsSupport.apply(
                proposal,
                to: textView,
                editingGuard: editingBehaviorGuard
            )
        case .textMutation:
            performPreflightedTextMutation(in: textView) {
                _ = EditingBehaviorsSupport.apply(
                    proposal,
                    to: textView,
                    editingGuard: editingBehaviorGuard
                )
            }
        }
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
        guard performPreflightedTextMutation(in: textView, {
            EditorCompletionSupport.insert(
                item.completion,
                into: textView,
                editingGuard: editingBehaviorGuard
            )
        }) else {
            return
        }
        recentCompletionIDs = EditorCompletionSupport.recentCompletionIDs(
            selecting: item.id,
            existing: recentCompletionIDs
        )
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
        performPreflightedTextMutation(in: textView) {
            EditingBehaviorsSupport.applyReplacement(
                replacement,
                replacementRange: selectionRange,
                newSelection: newSelection,
                to: textView,
                editingGuard: editingBehaviorGuard
            )
        }
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
        guard let imageAssetInserter,
              beginAsynchronousTextMutationLease(in: textView)
        else {
            return
        }
        let capturedText = MarkdownTextView.textStorage(of: textView)?.string ?? textView.text ?? ""
        let context = EditorImageAssetInsertionContext(
            text: capturedText,
            replacementRange: replacementRange.clamped(toLength: (capturedText as NSString).length),
            imageAssetContextID: imageAssetContextID,
            generation: imageAssetInsertionGeneration,
            requiresPublicationProof: installedDocument.hasSourceContract
        )

        Task { @MainActor [self, weak textView] in
            var isLeaseActive = true
            defer {
                if isLeaseActive {
                    endAsynchronousTextMutationLease()
                }
            }
            guard let textView else { return }
            let transaction = await imageAssetInserter(assets)
            endAsynchronousTextMutationLease()
            isLeaseActive = false
            guard commitImageAssetInsertion(
                transaction,
                in: textView,
                context: context
            ) else {
                await transaction.discard()
                return
            }
        }
    }

    private func commitImageAssetInsertion(
        _ transaction: EditorImageAssetInsertion,
        in textView: MarkdownSTTextView,
        context: EditorImageAssetInsertionContext
    ) -> Bool {
        let relativePaths = transaction.relativePaths
        guard !relativePaths.isEmpty,
              imageAssetInsertionGeneration == context.generation,
              imageAssetContextID == context.imageAssetContextID,
              !context.requiresPublicationProof || installedDocument.hasSourceContract,
              MarkdownEditing.shouldHandleBehavior(hasMarkedText: textView.hasMarkedText())
        else {
            return false
        }

        let insertion = relativePaths
            .map { SmartPaste.imageInsertion(relativePath: $0) }
            .joined(separator: "\n")
        let currentText = MarkdownTextView.textStorage(of: textView)?.string ?? textView.text ?? ""
        guard ExactSourceText.matches(currentText, context.text) else {
            return false
        }
        let replacementRange = context.replacementRange.clamped(toLength: (currentText as NSString).length)
        let newSelection = NSRange(
            location: replacementRange.location + (insertion as NSString).length,
            length: 0
        )
        let expectedText = (currentText as NSString).replacingCharacters(
            in: replacementRange,
            with: insertion
        )
        guard performPreflightedTextMutation(in: textView, {
            EditingBehaviorsSupport.applyReplacement(
                insertion,
                replacementRange: replacementRange,
                newSelection: newSelection,
                to: textView,
                editingGuard: editingBehaviorGuard
            )
        }) else {
            return false
        }

        let finalText = MarkdownTextView.textStorage(of: textView)?.string ?? textView.text ?? ""
        guard ExactSourceText.matches(finalText, expectedText) else { return false }
        guard context.requiresPublicationProof else { return true }
        guard let snapshot = currentInstalledSourceSnapshot else { return false }
        return ExactSourceText.matches(snapshot.source, expectedText) &&
            installedDocument.isSourceRevisionCurrent()
    }
}

private struct EditorImageAssetInsertionContext {
    let text: String
    let replacementRange: NSRange
    let imageAssetContextID: String?
    let generation: UInt64
    let requiresPublicationProof: Bool
}
