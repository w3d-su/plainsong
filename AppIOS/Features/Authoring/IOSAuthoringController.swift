import EditorKitIOS
import Foundation
import MarkdownCore

@MainActor
final class IOSAuthoringController: ObservableObject, IOSAuthoringActionProviding {
    let actions = IOSAuthoringCatalog.actions
    let findScheduler: any IOSAuthoringFindScheduling

    @Published var statusMessage = ""
    @Published var linkDraft: IOSLinkDraft?
    @Published var frontmatter = IOSFrontmatterModel()
    @Published var find = IOSFindModel()

    init(findScheduler: any IOSAuthoringFindScheduling = IOSAuthoringDetachedFindScheduler()) {
        self.findScheduler = findScheduler
    }

    func isEnabled(_ action: IOSAuthoringActionID, snapshot: IOSSourceEditorSnapshot?) -> Bool {
        guard let snapshot, snapshot.isFocused, !snapshot.hasMarkedText else { return false }
        switch action {
        case .find, .nextMatch, .previousMatch, .useSelectionForFind:
            return true
        case .bold, .italic, .link, .heading, .code, .strikethrough, .inlineCode, .paragraph,
             .quote, .codeFence, .inlineMath, .displayMath, .checkbox, .formatTable,
             .singleReplace:
            return snapshot.canWrite
        }
    }

    func perform(_ action: IOSAuthoringActionID, using editor: any IOSSourceEditorControlling) {
        switch action {
        case .find:
            find.isPresented = true
            beginFindQuery(using: editor)
        case .nextMatch:
            stepFind(by: 1, using: editor)
        case .previousMatch:
            stepFind(by: -1, using: editor)
        case .useSelectionForFind:
            useSelectionForFind(using: editor)
        case .singleReplace:
            replaceCurrentMatch(using: editor)
        case .link:
            performLink(using: editor)
        default:
            performFormat(action, using: editor)
        }
    }

    func performFormat(_ action: IOSAuthoringActionID, using editor: any IOSSourceEditorControlling) {
        guard let snapshot = editor.captureSnapshot() else { return }
        if snapshot.hasMarkedText {
            statusMessage = IOSAuthoringCatalog.compositionRefusal
            return
        }
        guard let command = editCommand(for: action) else { return }
        guard let planned = MarkdownEditing.apply(
            command,
            to: snapshot.document.text,
            selection: snapshot.selection,
            fileKind: snapshot.document.fileKind
        ) else {
            statusMessage = IOSAuthoringCatalog.formattingRefusal
            return
        }
        if planned.replacementString.isEmpty, planned.replacementRange.length == 0 {
            _ = editor.reveal(planned.newSelection, expected: snapshot.revision)
            return
        }
        submit(planned, snapshot: snapshot, name: IOSAuthoringCatalog.title(for: action), using: editor)
    }

    @discardableResult
    func submit(
        _ result: MarkdownEditResult,
        snapshot: IOSSourceEditorSnapshot,
        name: String,
        using editor: any IOSSourceEditorControlling
    ) -> IOSEditOutcome {
        let outcome = editor.apply(IOSAuthorizedEdit(
            bindingID: snapshot.bindingID,
            baseRevision: snapshot.revision,
            selectionGeneration: snapshot.selectionGeneration,
            accessGeneration: snapshot.accessGeneration,
            result: result,
            undoActionName: name
        ))
        if case .refused = outcome {
            statusMessage = IOSAuthoringCatalog.editRefusal
        } else {
            statusMessage = ""
        }
        return outcome
    }

    private func editCommand(for action: IOSAuthoringActionID) -> MarkdownEditCommand? {
        switch action {
        case .bold: .format(.bold)
        case .italic: .format(.italic)
        case .code, .inlineCode: .format(.inlineCode)
        case .strikethrough: .format(.strikethrough)
        case let .heading(level): .format(.heading(level: level))
        case .paragraph: .format(.paragraph)
        case .quote: .format(.quote)
        case .codeFence: .format(.codeFence)
        case .inlineMath: .format(.insertInlineMath)
        case .displayMath: .format(.insertDisplayMath)
        case .checkbox: .toggleCheckbox
        case .formatTable: .formatTable
        case .link, .find, .nextMatch, .previousMatch, .useSelectionForFind, .singleReplace:
            nil
        }
    }
}
