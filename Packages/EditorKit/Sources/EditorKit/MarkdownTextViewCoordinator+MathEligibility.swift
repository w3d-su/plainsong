import AppKit
import MarkdownCore
import STTextView

extension MarkdownTextViewCoordinator {
    /// Wires this editor's first-responder transitions into the shared
    /// math-command eligibility store so the Format menu tracks the focused
    /// editor only.
    ///
    /// Authority is the key window's first responder. A background window keeps
    /// its own first responder across representable updates; that update must
    /// not activate itself, and becoming key later has to publish without a
    /// new focus transition.
    ///
    /// Called on every representable update, so it is idempotent: handlers are
    /// installed once and window observers only move when the window changes.
    func attachMathCommandEligibility(to textView: MarkdownSTTextView) {
        guard !isMathEligibilityAttached else {
            syncMathEligibilityWindow(for: textView)
            return
        }
        isMathEligibilityAttached = true
        textView.firstResponderChangeHandler = { [weak self] view, isFocused in
            // A hosted window that is not key must not publish. A view with no
            // window (synthetic focus in tests, or before attachment) keeps the
            // direct handler path.
            if let window = view.window, !window.isKeyWindow {
                return
            }
            if isFocused {
                EditorMathCommandEligibility.shared.activate(view)
                self?.refreshMathCommandEligibility(for: view)
            } else {
                EditorMathCommandEligibility.shared.deactivate(view)
            }
        }
        // The view can join its window after the last representable update;
        // follow window moves directly instead of waiting for another update.
        textView.windowChangeHandler = { [weak self] view in
            self?.syncMathEligibilityWindow(for: view)
        }
        syncMathEligibilityWindow(for: textView)
    }

    func detachMathCommandEligibility(from textView: MarkdownSTTextView) {
        textView.firstResponderChangeHandler = nil
        textView.windowChangeHandler = nil
        isMathEligibilityAttached = false
        mathEligibilityWindowObservers = []
        mathEligibilityObservedWindow = nil
        EditorMathCommandEligibility.shared.deactivate(textView)
    }

    func activateMathCommandEligibilityIfAuthoritative(_ textView: MarkdownSTTextView) {
        guard textView.firstResponderChangeHandler != nil,
              let window = textView.window,
              window.isKeyWindow,
              window.firstResponder === textView
        else { return }
        EditorMathCommandEligibility.shared.activate(textView)
        refreshMathCommandEligibility(for: textView)
    }

    /// Re-targets the key-window observers when the hosting window changes and
    /// re-checks authority for the new window. A no-op when nothing moved.
    private func syncMathEligibilityWindow(for textView: MarkdownSTTextView) {
        let window = textView.window
        let isObserving = !mathEligibilityWindowObservers.isEmpty
        guard mathEligibilityObservedWindow !== window || (window != nil && !isObserving) else { return }

        mathEligibilityWindowObservers = []
        mathEligibilityObservedWindow = window
        guard let window else {
            EditorMathCommandEligibility.shared.deactivate(textView)
            return
        }
        installMathEligibilityWindowObservers(on: window, for: textView)
        activateMathCommandEligibilityIfAuthoritative(textView)
    }

    private func installMathEligibilityWindowObservers(on window: NSWindow, for textView: MarkdownSTTextView) {
        let center = NotificationCenter.default
        let become = center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self, weak textView] _ in
            Task { @MainActor [weak self, weak textView] in
                guard let self, let textView else { return }
                activateMathCommandEligibilityIfAuthoritative(textView)
            }
        }
        let resign = center.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak textView] _ in
            Task { @MainActor [weak textView] in
                guard let textView, textView.window?.isKeyWindow != true else { return }
                EditorMathCommandEligibility.shared.deactivate(textView)
            }
        }
        mathEligibilityWindowObservers = [
            CoordinatorNotificationObserver(become),
            CoordinatorNotificationObserver(resign),
        ]
    }

    /// Recomputes eligibility after selection, text, file-kind, or marked-text
    /// changes. Only the active (focused, key-window) editor does any work;
    /// every other editor's result would be dropped by the store anyway.
    ///
    /// The zone scan is too heavy for the keystroke path on large documents
    /// (~200 ms/MB), so it runs detached — at most one in flight, coalescing
    /// further changes into a single trailing pass that takes its own snapshot.
    /// The document snapshot is therefore captured only when a scan actually
    /// starts. A newer generation invalidates an in-flight result; blocked
    /// states (marked text, guarded mutation) publish `false` immediately.
    func refreshMathCommandEligibility(for textView: STTextView) {
        mathEligibilityGeneration &+= 1
        let generation = mathEligibilityGeneration

        guard EditorMathCommandEligibility.shared.isActive(textView) else {
            mathEligibilityPending = false
            return
        }

        guard !editingBehaviorGuard.isApplying,
              MarkdownEditing.shouldHandleBehavior(hasMarkedText: textView.hasMarkedText())
        else {
            mathEligibilityPending = false
            EditorMathCommandEligibility.shared.publish(
                MarkdownMathCommandAvailability(),
                for: textView
            )
            return
        }

        guard !mathEligibilityInFlight else {
            mathEligibilityPending = true
            return
        }
        mathEligibilityInFlight = true

        // Value-type snapshots: `textStorage.string` copies the current content,
        // so the detached scan sees a stable document while editing continues.
        let text = MarkdownTextView.textStorage(of: textView)?.string ?? textView.text ?? ""
        let selection = textView.selectedRange()
        let fileKind = commandProxy?.currentFileKind() ?? .markdown

        Task.detached { [weak self, weak textView] in
            let availability = MarkdownEditing.mathCommandAvailability(
                in: text,
                selection: selection,
                fileKind: fileKind
            )
            await MainActor.run { [weak self, weak textView] in
                guard let self else { return }
                // Clear the in-flight flag before anything can bail out, or a
                // released text view would freeze every later refresh.
                mathEligibilityInFlight = false
                let isPending = mathEligibilityPending
                mathEligibilityPending = false
                guard let textView else { return }
                if mathEligibilityGeneration == generation {
                    EditorMathCommandEligibility.shared.publish(availability, for: textView)
                }
                if isPending {
                    refreshMathCommandEligibility(for: textView)
                }
            }
        }
    }
}
