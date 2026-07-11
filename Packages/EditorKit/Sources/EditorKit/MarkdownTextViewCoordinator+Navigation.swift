import AppKit
import STTextView

extension MarkdownTextViewCoordinator {
    func observeNavigationCommand(_ command: EditorNavigationCommand?) {
        switch navigationState.observe(command) {
        case .acceptedNavigation, .acceptedCancellation:
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
           MarkdownTextView.plainTextMatches(textView, text),
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

        guard navigationEffects(for: textView, window: window).perform(selection: request.selection) else {
            return false
        }

        selection = request.selection
        didComplete = true
        return true
    }

    private func navigationEffects(for textView: STTextView, window: NSWindow) -> EditorNavigationEffects {
        EditorNavigationEffects(
            applySelection: { selection in
                textView.textSelection = selection
                return textView.selectedRange() == selection
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
