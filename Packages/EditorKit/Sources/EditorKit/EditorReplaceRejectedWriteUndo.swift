import AppKit
import MarkdownCore
import STTextView

/// Keeps a single Replace whose write was not applied from leaving an undo step.
///
/// STTextView registers the undo group for a native insert **after** it has notified the
/// delegate, and the coordinator settles a rejected publication inside that notification by
/// restoring the authoritative source. Without this guard the insert's group is still
/// registered afterwards, so `.refused(.writeNotApplied)` would leave a no-op step that
/// swallows the user's next Undo. The guard observes the executor's own write only: when the
/// text-did-change notification shows the exact pre-write source at the pre-write revision in
/// both the App snapshot and the native view, it disables undo registration until the insert
/// returns. Nothing is rolled back and no undo action is written by hand; an applied,
/// reconciled, or unobservable write registers its native group exactly as before.
@MainActor
final class EditorReplaceRejectedWriteUndo {
    private weak var textView: STTextView?
    private weak var coordinator: MarkdownTextViewCoordinator?
    private let preWriteSource: String
    private let preWriteRevision: Int
    private var observer: NSObjectProtocol?
    private(set) var didSuppressUndoRegistration = false

    init(
        textView: STTextView,
        coordinator: MarkdownTextViewCoordinator,
        preWriteSource: String,
        preWriteRevision: Int
    ) {
        self.textView = textView
        self.coordinator = coordinator
        self.preWriteSource = preWriteSource
        self.preWriteRevision = preWriteRevision
    }

    /// Runs `write` with the guard armed and always restores undo registration afterwards.
    func guarding(_ write: () -> Void) {
        observer = NotificationCenter.default.addObserver(
            forName: STTextView.textDidChangeNotification,
            object: textView,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.textDidChange()
            }
        }
        defer { finish() }
        write()
    }

    private func textDidChange() {
        guard !didSuppressUndoRegistration,
              let textView,
              let coordinator,
              let undoManager = textView.undoManager,
              undoManager.isUndoRegistrationEnabled,
              let snapshot = coordinator.currentInstalledSourceSnapshot,
              snapshot.revision == preWriteRevision,
              ExactSourceText.matches(snapshot.source, preWriteSource),
              ExactSourceText.matches(
                  MarkdownTextView.textStorage(of: textView)?.string ?? textView.text ?? "",
                  preWriteSource
              )
        else {
            return
        }
        undoManager.disableUndoRegistration()
        didSuppressUndoRegistration = true
    }

    private func finish() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        if didSuppressUndoRegistration {
            textView?.undoManager?.enableUndoRegistration()
        }
    }
}
