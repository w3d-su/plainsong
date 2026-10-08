import EditorKitIOS
import Foundation
import MarkdownCore

extension IOSAuthoringController {
    func setLinkLabel(_ label: String) {
        linkDraft?.label = label
    }

    func setLinkURL(_ url: String) {
        linkDraft?.url = url
    }

    func confirmLink(using editor: any IOSSourceEditorControlling) {
        guard let draft = linkDraft else { return }
        guard let result = IOSAuthoringLink.submission(
            planned: draft.planned,
            label: draft.label,
            url: draft.url
        ) else {
            statusMessage = IOSAuthoringCatalog.formattingRefusal
            return
        }
        let outcome = submit(result, snapshot: draft.snapshot, name: "Link", using: editor)
        if case .applied = outcome {
            linkDraft = nil
        }
    }

    func performLink(using editor: any IOSSourceEditorControlling) {
        guard let snapshot = editor.captureSnapshot() else { return }
        if snapshot.hasMarkedText {
            statusMessage = IOSAuthoringCatalog.compositionRefusal
            return
        }
        guard let planned = MarkdownEditing.apply(
            .format(.link),
            to: snapshot.document.text,
            selection: snapshot.selection,
            fileKind: snapshot.document.fileKind
        ) else {
            statusMessage = IOSAuthoringCatalog.formattingRefusal
            return
        }
        guard IOSAuthoringLink.needsSheet(planned) else {
            submit(planned, snapshot: snapshot, name: "Link", using: editor)
            return
        }
        linkDraft = IOSLinkDraft(
            snapshot: snapshot,
            planned: planned,
            collectsLabel: IOSAuthoringLink.collectsLabel(planned)
        )
    }
}
