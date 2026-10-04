import AppKit
import STTextView

@MainActor
public extension EditorReplaceCommandDispatcher {
    /// Command-entry composition check without exporting a concrete editor to App.
    static func batchEditorHasMarkedText(matching expected: EditorReplaceEditorStamp) -> Bool {
        guard let window = keyWindow, let textView = installedEditor(in: window),
              stamp(of: textView, in: window) == expected
        else { return false }
        return textView.hasMarkedText()
    }

    static func sendBatch(_ command: EditorReplaceBatchCommand) -> EditorReplaceBatchDelivery {
        guard let window = keyWindow else { return .notDelivered(.noKeyWindow) }
        guard let textView = responderChainEditor(in: window) else {
            return .notDelivered(.noEditorOnResponderChain)
        }
        return deliverBatch(command, to: textView, in: window)
    }

    static func sendBatchToKeyWindowEditor(
        _ command: EditorReplaceBatchCommand
    ) -> EditorReplaceBatchDelivery {
        guard let window = keyWindow else { return .notDelivered(.noKeyWindow) }
        guard let textView = installedEditor(in: window) else {
            return .notDelivered(.noEditorInKeyWindow)
        }
        return deliverBatch(command, to: textView, in: window)
    }

    private static func deliverBatch(
        _ command: EditorReplaceBatchCommand,
        to textView: STTextView,
        in window: NSWindow
    ) -> EditorReplaceBatchDelivery {
        guard let coordinator = textView.textDelegate as? MarkdownTextViewCoordinator,
              let stamp = stamp(of: textView, in: window),
              command.installations.contains(stamp.installation)
        else {
            return .notDelivered(.editorNotInstalled)
        }
        guard stamp == command.editorStamp else {
            return .notDelivered(.staleEditorStamp)
        }
        return .delivered(coordinator.performBatchReplace(
            command.request,
            prepared: command.prepared,
            authorization: command.authorization,
            controller: command.controller,
            recheck: command.recheck,
            in: textView
        ))
    }
}
