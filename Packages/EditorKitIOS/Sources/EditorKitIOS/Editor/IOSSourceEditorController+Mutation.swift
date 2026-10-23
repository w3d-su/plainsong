import MarkdownCore
import UIKit

extension IOSSourceEditorController {
    public func apply(_ edit: IOSAuthorizedEdit) -> IOSEditOutcome {
        if let refusal = refusal(for: edit) {
            return .refused(refusal)
        }
        guard let installation else { return .refused(.unavailable) }
        isMutating = true
        beforeNativeMutation?(self)
        isMutating = false
        if let refusal = refusal(for: edit) {
            return .refused(refusal)
        }
        guard commit(edit.result, actionName: edit.undoActionName) else {
            return .refused(.invalidRange)
        }
        publishCurrentText()
        consumeSelectionEpoch()
        scheduleHighlight()
        emitSnapshot()
        return .applied(IOSDocumentRevision(
            documentID: installation.identity,
            version: installation.session.version
        ))
    }

    public func reveal(_ range: NSRange, expected: IOSDocumentRevision) -> Bool {
        guard isHostAlive, textView.isTextKit2, let installation else { return false }
        guard installation.identity == expected.documentID,
              installation.session.version == expected.version,
              textView.markedTextRange == nil,
              !isMutating
        else {
            return false
        }
        let length = textView.textStorage.length
        guard IOSTextRanges.contains(range, length: length) || (range.length == 0 && range.location <= length) else {
            return false
        }
        isAdjustingSelection = true
        textView.selectedRange = range
        textView.scrollRangeToVisible(range)
        isAdjustingSelection = false
        consumeSelectionEpoch()
        emitSnapshot()
        return true
    }

    public func undo() {
        guard canUseHistory() else { return }
        textView.undoManager?.undo()
    }

    public func redo() {
        guard canUseHistory() else { return }
        textView.undoManager?.redo()
    }

    func performOutdent() {
        guard let installation, installation.canWrite, textView.markedTextRange == nil, !isMutating else {
            return
        }
        let selection = textView.selectedRange
        guard let result = MarkdownEditing.apply(
            .insertTab(backwards: true),
            to: plainText(),
            selection: selection,
            fileKind: installation.session.fileKind
        ) else {
            return
        }
        _ = commit(result, actionName: "Outdent")
        publishCurrentText()
        consumeSelectionEpoch()
        scheduleHighlight()
        emitSnapshot()
    }

    /// Returns true when the default insertion must not also run.
    func consumeReplacement(_ text: String, range: NSRange) -> Bool {
        if isMutating || isReconciling {
            return false
        }
        guard isHostAlive, let installation else { return true }
        if textView.markedTextRange != nil {
            return false
        }
        guard installation.canWrite else { return true }
        let fileKind = installation.session.fileKind
        guard IOSEditorBehavior.needsEvaluation(text, fileKind: fileKind),
              let command = IOSEditorBehavior.command(for: text, fileKind: fileKind),
              let result = MarkdownEditing.apply(
                  command,
                  to: plainText(),
                  selection: range,
                  fileKind: fileKind
              )
        else {
            return false
        }
        _ = commit(result, actionName: IOSEditorBehavior.undoActionName(for: command))
        publishCurrentText()
        consumeSelectionEpoch()
        scheduleHighlight()
        emitSnapshot()
        return true
    }

    func refusal(for edit: IOSAuthorizedEdit) -> IOSEditRefusal? {
        guard isHostAlive, textView.isTextKit2 else { return .unavailable }
        guard let installation else { return .unavailable }
        if let identityRefusal = identityRefusal(for: edit, installation: installation) {
            return identityRefusal
        }
        return writerRefusal(for: edit, installation: installation)
    }

    private func identityRefusal(
        for edit: IOSAuthorizedEdit,
        installation: IOSSourceEditorDocumentBinding
    ) -> IOSEditRefusal? {
        if edit.bindingID != installation.bindingID {
            return .bindingChanged
        }
        if edit.baseRevision.documentID != installation.identity {
            return .documentChanged
        }
        if edit.baseRevision.version != installation.session.version {
            return .sourceChanged
        }
        if !ExactSourceFragment.matches(plainText(), installation.session.text) {
            return .sourceChanged
        }
        if edit.selectionGeneration != selectionGeneration {
            return .selectionChanged
        }
        return nil
    }

    private func writerRefusal(
        for edit: IOSAuthorizedEdit,
        installation: IOSSourceEditorDocumentBinding
    ) -> IOSEditRefusal? {
        if edit.accessGeneration != installation.accessGeneration {
            return .accessChanged
        }
        if !installation.canWrite {
            return .readOnly
        }
        if textView.markedTextRange != nil {
            return .markedText
        }
        if !isCommandFocused {
            return .notFocused
        }
        if isMutating || isReconciling {
            return .busy
        }
        if !isValid(edit.result) {
            return .invalidRange
        }
        return nil
    }

    private func commit(_ result: MarkdownEditResult, actionName: String) -> Bool {
        if result.replacementString.isEmpty, result.replacementRange.length == 0 {
            guard isValidSelection(result.newSelection, length: textView.textStorage.length) else {
                return false
            }
            isAdjustingSelection = true
            textView.selectedRange = result.newSelection
            isAdjustingSelection = false
            return true
        }
        guard isValid(result) else { return false }
        isMutating = true
        defer { isMutating = false }
        return IOSNativeTextMutation.replace(result, in: textView, actionName: actionName)
    }

    private func isValid(_ result: MarkdownEditResult) -> Bool {
        let length = textView.textStorage.length
        guard IOSTextRanges.contains(result.replacementRange, length: length) else { return false }
        let replacementLength = IOSTextRanges.utf16Length(of: result.replacementString)
        let nextLength = length - result.replacementRange.length + replacementLength
        return isValidSelection(result.newSelection, length: nextLength)
    }

    private func isValidSelection(_ range: NSRange, length: Int) -> Bool {
        range.location >= 0 && range.length >= 0 && NSMaxRange(range) <= length
    }

    private func canUseHistory() -> Bool {
        isHostAlive && isCommandFocused && installation != nil && textView.markedTextRange == nil && !isMutating
    }

    func publishCurrentText() {
        guard let installation else { return }
        let current = plainText()
        guard !ExactSourceFragment.matches(current, installation.session.text) else { return }
        installation.session.replaceTextFromAuthorizedEditor(current, refreshStatistics: false)
        let version = installation.session.version
        let session = installation.session
        Task { @MainActor in
            let statistics = await Task.detached(priority: .utility) {
                TextStatistics(text: current)
            }.value
            guard session.version == version, ExactSourceFragment.matches(session.text, current) else { return }
            session.applyStatistics(statistics)
        }
    }

    func consumeSelectionEpoch() {
        selectionGeneration &+= 1
        lastSelection = textView.selectedRange
    }
}
