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
        visibleRangeObserver = nil
        visibleRangeTextView = nil
        visibleRangeChangeHandler = nil
        lastVisibleTextRange = nil
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
        guard let visibleRange = MarkdownTextView.visibleTextRange(of: textView),
              visibleRange != lastVisibleTextRange
        else {
            return
        }

        lastVisibleTextRange = visibleRange
        scrollProxy?.emitVisibleLine(containingUTF16Offset: visibleRange.location, in: textView)
        visibleRangeChangeHandler?(visibleRange)
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
