import AppKit
import MarkdownCore
import STTextView

@MainActor
extension MarkdownTextViewCoordinator {
    func attachScrollProxy(_ proxy: EditorScrollProxy?, to textView: STTextView) {
        if scrollProxy !== proxy {
            scrollProxy?.detach()
            scrollProxy = proxy
        }

        proxy?.attach(to: textView)
    }

    func detachScrollProxy() {
        scrollProxy?.detach()
        scrollProxy = nil
    }

    func attachVisibleRangeReporter(_ handler: @escaping (NSRange) -> Void, to textView: STTextView) {
        visibleRangeChangeHandler = handler

        if visibleRangeTextView !== textView {
            visibleRangeObserver = nil
            visibleRangeTextView = textView
            lastVisibleTextRange = nil
            lastCacheTrimSelection = nil

            if let clipView = textView.enclosingScrollView?.contentView {
                clipView.postsBoundsChangedNotifications = true
                visibleRangeObserver = CoordinatorNotificationObserver(NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: clipView,
                    queue: .main
                ) { [weak self, weak textView] _ in
                    Task { @MainActor [weak self, weak textView] in
                        guard let textView else { return }
                        self?.reportVisibleRangeIfNeeded(in: textView)
                    }
                })
            }
        }

        reportVisibleRangeIfNeeded(in: textView)
    }

    func detachVisibleRangeReporter() {
        textElementCacheTrimmer.cancel()
        visibleRangeObserver = nil
        visibleRangeTextView = nil
        visibleRangeChangeHandler = nil
        lastVisibleTextRange = nil
        lastCacheTrimSelection = nil
    }

    func attachCommandProxy(_ proxy: EditorCommandProxy?, to textView: STTextView) {
        if commandProxy !== proxy {
            commandProxy?.detach(from: textView)
            commandProxy = proxy
        }

        proxy?.attach(
            to: textView,
            fileKind: proxy?.currentFileKind() ?? .markdown
        ) { [weak self, weak textView] command in
            guard let self, let textView else { return }
            performCommand(command, in: textView)
        }
    }

    func detachCommandProxy(from textView: STTextView) {
        commandProxy?.detach(from: textView)
        commandProxy = nil
    }

    func updateCompletionWorkspace(_ workspace: CompletionWorkspace) {
        completionWorkspace = workspace
    }

    func updateImageAssetInserter(_ inserter: EditorImageAssetInserter?) {
        imageAssetInserter = inserter
    }

    func updateImageAssetContextID(_ contextID: String?) {
        if !imageAssetContextIDMatches(contextID) {
            imageAssetInsertionGeneration &+= 1
        }
        imageAssetContextID = contextID
    }

    func imageAssetContextIDMatches(_ contextID: String?) -> Bool {
        switch (imageAssetContextID, contextID) {
        case (nil, nil):
            true
        case let (current?, candidate?):
            ExactSourceText.matches(current, candidate)
        default:
            false
        }
    }

    func reportVisibleRangeIfNeeded(in textView: STTextView) {
        guard let visibleRange = MarkdownTextView.visibleTextRange(of: textView) else {
            return
        }
        let viewportChanged = visibleRange != lastVisibleTextRange
        if viewportChanged {
            lastVisibleTextRange = visibleRange
            // The range includes TextKit's prefetch band above the visible area; scroll
            // sync needs the line the user sees at the top.
            scrollProxy?.emitVisibleLine(
                containingUTF16Offset: EditorVisibleTop.utf16Offset(in: textView) ?? visibleRange.location,
                in: textView
            )
            visibleRangeChangeHandler?(visibleRange)
        }
        // Selection protection can refuse a trim even while the viewport stays fixed.
        // Retry when that input range changes, without republishing visible text or
        // restarting the settle timer for duplicate selection/attribute notifications.
        let selection = textView.selectedRange()
        guard viewportChanged || selection != lastCacheTrimSelection else { return }
        lastCacheTrimSelection = selection
        textElementCacheTrimmer.visibleRangeDidChange(visibleRange, in: textView) { [weak self] in
            guard let self else { return false }
            return !isUpdating && !hasPendingWriterLease
        }
    }
}

final class CoordinatorNotificationObserver {
    private let token: NSObjectProtocol

    init(_ token: NSObjectProtocol) {
        self.token = token
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}
