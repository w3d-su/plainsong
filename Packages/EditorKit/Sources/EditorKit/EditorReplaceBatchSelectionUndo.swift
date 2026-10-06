import AppKit
import STTextView

/// Native text undo owns source restoration. This action restores selection only
/// after the same native Undo/Redo group has finished, so STTextView's own range
/// restoration cannot overwrite it. Registration waits until the insert returns;
/// rejected writes therefore create neither a selection action nor an undo step.
@MainActor
final class EditorReplaceBatchSelectionUndo {
    private weak var textView: STTextView?

    init(textView: STTextView) {
        self.textView = textView
    }

    func register(priorSelection: NSRange, postSelection: NSRange) {
        textView?.undoManager?.registerUndo(withTarget: self) { [self] _ in
            restoreAfterNativeGroup(priorSelection, inverse: postSelection)
        }
    }

    private func restoreAfterNativeGroup(_ selection: NSRange, inverse: NSRange) {
        guard let view = textView, let manager = view.undoManager else { return }
        let notification = manager.isUndoing
            ? Notification.Name.NSUndoManagerDidUndoChange
            : Notification.Name.NSUndoManagerDidRedoChange
        let lifetime = BatchSelectionUndoNotificationLifetime()
        lifetime.observer = NotificationCenter.default.addObserver(
            forName: notification, object: manager, queue: nil
        ) { [weak view, lifetime] _ in
            MainActor.assumeIsolated {
                lifetime.stop()
                view?.textSelection = selection
            }
        }
        manager.registerUndo(withTarget: self) { [self] _ in
            restoreAfterNativeGroup(inverse, inverse: selection)
        }
    }
}

private final class BatchSelectionUndoNotificationLifetime: @unchecked Sendable {
    var observer: NSObjectProtocol?

    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
    }
}
