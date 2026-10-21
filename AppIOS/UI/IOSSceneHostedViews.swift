import EditorKitIOS
import Foundation
import PreviewKitContracts
import UIKit

/// Retains the scene's single editor and preview host views. The factories run
/// at most once per capability instance; layout transitions, re-renders and
/// even representable re-creation always reuse the same native view, so
/// selection/scroll/Undo/composition can only change through a real attach.
@MainActor
final class IOSSceneHostedViews {
    private var retainedEditor: UIView?
    private var retainedPreview: UIView?
    private var editorSourceID: ObjectIdentifier?
    private var previewSourceID: ObjectIdentifier?

    func editorView(
        for binding: (any IOSSourceEditorBinding)?,
        make: ((any IOSSourceEditorBinding) -> UIView?)?
    ) -> UIView? {
        guard let binding else {
            // Capability retracted: drop the retained host so a later
            // capability of a different identity can never revive a stale view.
            editorSourceID = nil
            retainedEditor = nil
            return nil
        }
        let identifier = ObjectIdentifier(binding)
        if editorSourceID == identifier, let retainedEditor {
            return retainedEditor
        }
        guard let make else { return nil }
        let view = make(binding)
        retainedEditor = view
        editorSourceID = view == nil ? nil : identifier
        return view
    }

    func previewView(
        for controller: (any IOSPreviewControlling)?,
        make: ((any IOSPreviewControlling) -> UIView?)?
    ) -> UIView? {
        guard let controller else {
            previewSourceID = nil
            retainedPreview = nil
            return nil
        }
        let identifier = ObjectIdentifier(controller)
        if previewSourceID == identifier, let retainedPreview {
            return retainedPreview
        }
        guard let make else { return nil }
        let view = make(controller)
        retainedPreview = view
        previewSourceID = view == nil ? nil : identifier
        return view
    }
}
