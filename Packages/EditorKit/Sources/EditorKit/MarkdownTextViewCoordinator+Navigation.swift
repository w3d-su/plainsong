import AppKit
import STTextView

#if DEBUG
    import Combine
#endif

extension MarkdownTextViewCoordinator {
    func observeNavigationCommand(_ command: EditorNavigationCommand?) {
        switch navigationState.observe(command) {
        case .acceptedNavigation:
            cancelPendingNavigationTasks()
        case .acceptedCancellation:
            cancelPendingNavigationTasks()
        case .ignored:
            break
        }
    }

    @discardableResult
    func applyPendingNavigationIfPossible(
        in textView: STTextView,
        schedulesRetry: Bool = true
    ) -> EditorNavigationDecision {
        guard !isApplyingNavigation else {
            return .noRequest
        }

        let hasMarkedText = textView.hasMarkedText()
        var isDocumentTextInstalled = false
        var documentTextUTF16Length = 0

        // Preserve the String-only ordinary update path: this exact full-text check
        // runs only for a pending request that targets the currently bound document.
        if let request = navigationState.pendingRequest,
           request.documentIdentity == currentDocumentIdentity,
           isPreparedDocumentInstalled,
           !hasMarkedText,
           canProveCurrentInstalledSource() || nativeTextMatches(textView, text),
           let textStorage = MarkdownTextView.textStorage(of: textView)
        {
            isDocumentTextInstalled = true
            documentTextUTF16Length = textStorage.length
        }

        let window = textView.window
        let isAttached = window != nil
            && textView.enclosingScrollView?.window === window
            && textView.acceptsFirstResponder
            && textView.isSelectable
        let context = EditorNavigationContext(
            documentIdentity: currentDocumentIdentity,
            isDocumentTextInstalled: isDocumentTextInstalled,
            documentTextUTF16Length: documentTextUTF16Length,
            hasMarkedText: hasMarkedText,
            isAttached: isAttached
        )
        let decision = navigationState.nextDecision(in: context)

        switch decision {
        case let .ready(request):
            if performNavigation(request, in: textView) {
                navigationState.markHandled(request)
                cancelPendingNavigationTasks()
            } else if schedulesRetry {
                scheduleNavigationRetry(for: request, in: textView)
            }
        case .rejected:
            cancelPendingNavigationTasks()
        case .noRequest, .pending:
            break
        }

        return decision
    }

    func cancelPendingNavigationTasks() {
        navigationRetryTask?.cancel()
        navigationRetryTask = nil
        navigationInputDeferralTask?.cancel()
        navigationInputDeferralTask = nil
    }

    func schedulePendingNavigationAfterInput(in textView: STTextView) {
        guard navigationState.pendingRequest != nil else { return }

        navigationInputDeferralTask?.cancel()
        navigationInputDeferralTask = Task { @MainActor [weak self, weak textView] in
            await Task.yield()
            guard !Task.isCancelled,
                  let self,
                  let textView
            else {
                return
            }

            navigationInputDeferralTask = nil
            _ = applyPendingNavigationIfPossible(in: textView)
        }
    }

    private func performNavigation(_ request: EditorNavigationRequest, in textView: STTextView) -> Bool {
        guard let window = textView.window,
              textView.enclosingScrollView?.window === window,
              textView.acceptsFirstResponder,
              textView.isSelectable
        else {
            return false
        }

        let originalSelection = textView.selectedRange()
        let clipView = textView.enclosingScrollView?.contentView
        let originalVisibleOrigin = clipView?.bounds.origin
        let previousIsUpdating = isUpdating
        let undoManager = textView.undoManager
        let shouldRestoreUndoRegistration = undoManager?.isUndoRegistrationEnabled == true
        var didComplete = false

        isApplyingNavigation = true
        isUpdating = true
        if shouldRestoreUndoRegistration {
            undoManager?.disableUndoRegistration()
        }
        defer {
            if shouldRestoreUndoRegistration {
                undoManager?.enableUndoRegistration()
            }
            if !didComplete {
                textView.textSelection = originalSelection
                if let clipView, let originalVisibleOrigin {
                    clipView.scroll(to: originalVisibleOrigin)
                    textView.enclosingScrollView?.reflectScrolledClipView(clipView)
                }
            }
            isUpdating = previousIsUpdating
            isApplyingNavigation = false
        }

        // Capture the focus *owner* before selection changes: STTextView may claim
        // first-responder when `textSelection` is set. Find navigation must restore the
        // find field so typing is not interrupted.
        let previousFocusOwner = Self.focusOwner(of: window.firstResponder)

        guard navigationEffects(for: textView, window: window).perform(
            selection: request.selection,
            shouldFocusEditor: request.shouldFocusEditor
        ) else {
            return false
        }
        // Programmatic navigation runs with `isUpdating` set, so the ordinary
        // selection-change callback cannot forward this applied line to scroll sync.
        // This forced intent is distinct from preference-gated viewport observation.
        scrollProxy?.emitNavigationLine(containingUTF16Offset: request.selection.location, in: textView)
        if !request.shouldFocusEditor {
            restoreFocusOwner(previousFocusOwner, in: window, editor: textView)
        }

        publishAppliedSelection(request.selection)
        publishNavigationDebugProbe(request)
        didComplete = true
        return true
    }

    private func publishNavigationDebugProbe(_ request: EditorNavigationRequest) {
        #if DEBUG
            Task { @MainActor in
                EditorNavigationDebugProbe.shared.publish(
                    documentIdentity: request.documentIdentity,
                    selection: request.selection
                )
            }
        #endif
    }

    /// The control that owns focus, not the transient object holding it.
    ///
    /// A focused `NSTextField` is *not* the window's first responder — its **field editor**
    /// is, and AppKit unmounts that shared editor from the control the moment the control
    /// resigns. Restoring the field editor object itself would therefore aim at a detached
    /// editor and leave focus on the window, so capture the owning control and let AppKit
    /// re-install its editor on the way back.
    /// Internal for `@testable` coverage: the end-to-end navigation test cannot force this
    /// path, because STTextView does not claim first responder on every layout.
    static func focusOwner(of responder: NSResponder?) -> NSResponder? {
        guard let textView = responder as? NSTextView, textView.isFieldEditor else {
            return responder
        }
        // AppKit points a field editor's delegate at the control currently using it.
        if let owner = textView.delegate as? NSResponder {
            return owner
        }
        return textView.superview ?? responder
    }

    /// Puts focus back where it was before a non-focusing navigation.
    ///
    /// Setting `textSelection` can make STTextView first responder on its own, which would
    /// steal typing from the find field mid-query. Restores only when the previous owner was
    /// something other than the editor and it no longer holds focus.
    func restoreFocusOwner(
        _ owner: NSResponder?,
        in window: NSWindow,
        editor textView: STTextView
    ) {
        guard let owner,
              owner !== textView,
              !Self.holdsFocus(owner, in: window)
        else {
            return
        }
        _ = window.makeFirstResponder(owner)
    }

    /// True when `owner` is focused either directly or through its field editor.
    private static func holdsFocus(_ owner: NSResponder, in window: NSWindow) -> Bool {
        if window.firstResponder === owner {
            return true
        }
        guard let control = owner as? NSControl,
              let editor = control.currentEditor()
        else {
            return false
        }
        return window.firstResponder === editor
    }

    private func navigationEffects(for textView: STTextView, window: NSWindow) -> EditorNavigationEffects {
        EditorNavigationEffects(
            applySelection: { selection in
                textView.textSelection = selection
                let applied = textView.selectedRange()
                // Force selection-highlight overlay rebuild; when the editor is not first
                // responder (find field owns focus), STTextView still draws unemphasized
                // selection but may need an explicit display pass after textSelections change.
                textView.needsDisplay = true
                textView.needsLayout = true
                return applied == selection
            },
            scrollRangeToVisible: { selection in
                textView.scrollRangeToVisible(selection)
            },
            focusEditor: {
                if window.firstResponder === textView {
                    return true
                }
                return window.makeFirstResponder(textView)
                    && window.firstResponder === textView
            }
        )
    }

    private func scheduleNavigationRetry(
        for request: EditorNavigationRequest,
        in textView: STTextView
    ) {
        navigationRetryTask?.cancel()
        navigationRetryTask = Task { @MainActor [weak self, weak textView] in
            defer {
                if self?.navigationState.pendingRequest == request {
                    self?.navigationRetryTask = nil
                }
            }

            for _ in 0 ..< 60 {
                do {
                    try await Task.sleep(nanoseconds: 50_000_000)
                } catch {
                    return
                }

                guard let self, let textView,
                      navigationState.pendingRequest == request
                else {
                    return
                }

                _ = applyPendingNavigationIfPossible(
                    in: textView,
                    schedulesRetry: false
                )
                if navigationState.pendingRequest != request {
                    return
                }
            }

            self?.navigationRetryTask = nil
        }
    }
}

#if DEBUG
    @MainActor
    final class EditorNavigationDebugProbe: ObservableObject {
        struct Observation: Equatable {
            let documentIdentity: EditorDocumentIdentity
            let selection: NSRange
        }

        static let shared = EditorNavigationDebugProbe()
        @Published private(set) var observation: Observation?

        func publish(documentIdentity: EditorDocumentIdentity, selection: NSRange) {
            observation = Observation(
                documentIdentity: documentIdentity,
                selection: selection
            )
        }
    }
#endif
