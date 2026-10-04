import AppKit
import STTextView

/// A preparation-only selection observation. App removes it before commit, so
/// Replace All adds no permanent work to the editor's selection or typing paths.
@MainActor
public final class EditorReplaceBatchSelectionObservation {
    private let lifetime = BatchSelectionObserverLifetime()

    init(textView: STTextView, onChange: @escaping @MainActor @Sendable () -> Void) {
        lifetime.observer = NotificationCenter.default.addObserver(
            forName: STTextView.didChangeSelectionNotification,
            object: textView,
            queue: nil
        ) { _ in
            MainActor.assumeIsolated { onChange() }
        }
    }

    public func stop() {
        lifetime.stop()
    }
}

@MainActor
public extension EditorReplaceCommandDispatcher {
    static func observeBatchSelectionChanges(
        _ onChange: @escaping @MainActor @Sendable () -> Void
    ) -> EditorReplaceBatchSelectionObservation? {
        guard let window = keyWindow,
              let textView = installedEditor(in: window),
              stamp(of: textView, in: window) != nil
        else { return nil }
        return EditorReplaceBatchSelectionObservation(textView: textView, onChange: onChange)
    }
}

/// The notification token has no actor-bound UI state. NotificationCenter removal
/// is thread safe, so its lifetime also cleans up when the public owner is released.
private final class BatchSelectionObserverLifetime: @unchecked Sendable {
    var observer: NSObjectProtocol?

    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
    }

    deinit { stop() }
}
