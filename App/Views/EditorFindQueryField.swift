import AppKit
import SwiftUI

/// Owned AppKit query field for in-document find (not SwiftUI `FocusState`).
///
/// Focus apply is **key-window only** and settled against the App-owned receipt in
/// `EditorFindUIState`. The retry loop re-reads that receipt plus live key-window state on
/// every iteration and consumes a token only after this field is the real first responder,
/// so a second `WindowGroup` window or a remounted bar can never replay a spent request.
struct EditorFindQueryField: NSViewRepresentable {
    @Binding var text: String
    var focusRequestID: UInt64
    var isEnabled: Bool
    /// Live arbitration inputs; read fresh inside the retry loop, never captured.
    var readFocusSnapshot: () -> EditorFindUIState.FocusSnapshot
    /// Advances the shared applied receipt. Only called after key-window first-responder proof.
    var markFocusApplied: (UInt64) -> Void
    var onSubmit: () -> Void
    var onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            readFocusSnapshot: readFocusSnapshot,
            markFocusApplied: markFocusApplied,
            onSubmit: onSubmit,
            onEscape: onEscape
        )
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        field.focusRingType = .default
        field.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        field.placeholderString = EditorFindAccessibility.queryFieldPlaceholder
        field.setAccessibilityLabel(EditorFindAccessibility.queryFieldLabel)
        field.setAccessibilityIdentifier(EditorFindAccessibility.queryField)
        field.delegate = context.coordinator
        field.isEditable = isEnabled
        field.isSelectable = true
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.text = $text
        coordinator.field = field
        coordinator.onSubmit = onSubmit
        coordinator.onEscape = onEscape
        coordinator.readFocusSnapshot = readFocusSnapshot
        coordinator.markFocusApplied = markFocusApplied

        // Never overwrite the field while IME marked text is active (Zhuyin/Pinyin).
        let isComposing: Bool = {
            if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() {
                return true
            }
            return coordinator.isComposing
        }()
        if !isComposing, field.stringValue != text {
            field.stringValue = text
        }
        field.isEditable = isEnabled
        field.setAccessibilityIdentifier(EditorFindAccessibility.queryField)

        let snapshot = readFocusSnapshot()
        if EditorFindFocusArbitration.shouldKeepRetrying(
            requestID: focusRequestID,
            snapshot: snapshot
        ) {
            // The field may not be in a key window yet (first ⌘F mounts the bar in the same
            // turn), so this schedules a bounded retry instead of one async attempt.
            coordinator.scheduleFocusAttempt(requestID: focusRequestID)
        } else {
            coordinator.cancelFocusAttempt()
            coordinator.applySelectAllIfAlreadyFocused(snapshot: snapshot)
        }
    }

    static func dismantleNSView(_: NSTextField, coordinator: Coordinator) {
        coordinator.cancelFocusAttempt()
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        /// 180 × 16 ms ≈ 3 s, matching the workspace-search focus loop's mount-race budget.
        private static let maximumAttempts = 180
        private static let retryIntervalNanoseconds: UInt64 = 16_000_000

        var text: Binding<String>
        var readFocusSnapshot: () -> EditorFindUIState.FocusSnapshot
        var markFocusApplied: (UInt64) -> Void
        var onSubmit: () -> Void
        var onEscape: () -> Void
        weak var field: NSTextField?
        var isComposing = false

        private var focusTask: Task<Void, Never>?
        private var focusTaskRequestID: UInt64?
        /// Select-all is per-field chrome, so it stays coordinator-local even though the
        /// focus receipt is App-owned.
        private var lastAppliedSelectAllRequestID: UInt64 = 0

        init(
            text: Binding<String>,
            readFocusSnapshot: @escaping () -> EditorFindUIState.FocusSnapshot,
            markFocusApplied: @escaping (UInt64) -> Void,
            onSubmit: @escaping () -> Void,
            onEscape: @escaping () -> Void
        ) {
            self.text = text
            self.readFocusSnapshot = readFocusSnapshot
            self.markFocusApplied = markFocusApplied
            self.onSubmit = onSubmit
            self.onEscape = onEscape
        }

        deinit {
            focusTask?.cancel()
        }

        func cancelFocusAttempt() {
            focusTask?.cancel()
            focusTask = nil
            focusTaskRequestID = nil
        }

        func scheduleFocusAttempt(requestID: UInt64) {
            guard focusTaskRequestID != requestID || focusTask == nil else { return }
            focusTask?.cancel()
            focusTaskRequestID = requestID
            focusTask = Task { @MainActor [weak self] in
                await self?.runFocusAttempt(requestID: requestID)
                if let self, focusTaskRequestID == requestID {
                    focusTask = nil
                    focusTaskRequestID = nil
                }
            }
        }

        private func runFocusAttempt(requestID: UInt64) async {
            for _ in 0 ..< Self.maximumAttempts {
                guard !Task.isCancelled else { return }
                let snapshot = readFocusSnapshot()
                guard EditorFindFocusArbitration.shouldKeepRetrying(
                    requestID: requestID,
                    snapshot: snapshot
                ) else {
                    return
                }
                if applyFocusIfEligible(requestID: requestID, snapshot: snapshot) {
                    return
                }
                do {
                    try await Task.sleep(nanoseconds: Self.retryIntervalNanoseconds)
                } catch {
                    return
                }
            }
        }

        /// Returns `true` once the shared receipt was advanced for `requestID`.
        @discardableResult
        func applyFocusIfEligible(
            requestID: UInt64,
            snapshot: EditorFindUIState.FocusSnapshot
        ) -> Bool {
            guard let field, let window = field.window else { return false }
            guard EditorFindFocusArbitration.shouldApplyFocus(
                requestID: requestID,
                appliedID: snapshot.appliedID,
                supersededID: snapshot.supersededID,
                isKeyWindow: window.isKeyWindow
            ) else {
                return false
            }
            guard window.makeFirstResponder(field), isFirstResponder(field, in: window) else {
                return false
            }
            // Re-read after `makeFirstResponder`: another window may have applied meanwhile.
            let settled = readFocusSnapshot()
            guard EditorFindFocusArbitration.shouldApplyFocus(
                requestID: requestID,
                appliedID: settled.appliedID,
                supersededID: settled.supersededID,
                isKeyWindow: window.isKeyWindow
            ) else {
                return false
            }
            markFocusApplied(requestID)
            applySelectAll(requestID: settled.selectAllRequestID, field: field)
            return true
        }

        /// ⌘F on an already-focused field only needs the select-all half.
        func applySelectAllIfAlreadyFocused(snapshot: EditorFindUIState.FocusSnapshot) {
            guard snapshot.isBarVisible,
                  snapshot.requestID == snapshot.appliedID,
                  snapshot.selectAllRequestID != lastAppliedSelectAllRequestID,
                  let field,
                  let window = field.window,
                  window.isKeyWindow,
                  isFirstResponder(field, in: window)
            else {
                return
            }
            applySelectAll(requestID: snapshot.selectAllRequestID, field: field)
        }

        private func applySelectAll(requestID: UInt64, field: NSTextField) {
            guard requestID != lastAppliedSelectAllRequestID else { return }
            lastAppliedSelectAllRequestID = requestID
            field.currentEditor()?.selectAll(nil)
        }

        private func isFirstResponder(_ field: NSTextField, in window: NSWindow) -> Bool {
            window.firstResponder === field || window.firstResponder === field.currentEditor()
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() {
                isComposing = true
                return
            }
            isComposing = false
            if text.wrappedValue != field.stringValue {
                text.wrappedValue = field.stringValue
            }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            isComposing = false
            if text.wrappedValue != field.stringValue {
                text.wrappedValue = field.stringValue
            }
        }

        func control(
            _: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            if textView.hasMarkedText() {
                if commandSelector == #selector(NSResponder.insertNewline(_:))
                    || commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
                    || commandSelector == #selector(NSResponder.cancelOperation(_:))
                {
                    return false
                }
            }

            if commandSelector == #selector(NSResponder.insertNewline(_:))
                || commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
            {
                onSubmit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                onEscape()
                return true
            }
            return false
        }
    }
}
