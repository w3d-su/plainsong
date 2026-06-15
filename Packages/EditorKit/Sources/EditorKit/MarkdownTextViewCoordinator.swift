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
    private var recentCompletionIDs: [String] = []
    private var completionRequestID = 0
    private var completionTask: Task<[Completion], Never>?

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

    func updateCompletionWorkspace(_ workspace: CompletionWorkspace) {
        completionWorkspace = workspace
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
    }

    private func requestCompletion(afterApplyingChangeIn textView: STTextView) {
        Task { @MainActor [weak textView] in
            await Task.yield()
            guard let textView, !textView.hasMarkedText() else { return }
            textView.complete(nil)
        }
    }
}
