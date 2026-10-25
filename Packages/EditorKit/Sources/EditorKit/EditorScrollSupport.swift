import AppKit
import STTextView

/// Distinguishes ordinary viewport observation from an explicit navigation that must
/// stay visible in every mounted presentation.
public enum EditorScrollIntent: Equatable, Sendable {
    case viewportChanged(line: Int)
    case navigation(line: Int, documentIdentity: EditorDocumentIdentity)
}

/// Public scroll bridge for the app layer. It intentionally exposes source-line
/// concepts only, keeping STTextView and TextKit details inside EditorKit.
@MainActor
public final class EditorScrollProxy: ObservableObject {
    public var onScrollIntent: ((EditorScrollIntent) -> Void)?

    private var attachment: EditorScrollAttachment?

    public init() {}

    public func scrollToLine(_ line: Int) {
        attachment?.scrollToLine(line)
    }

    func emitVisibleLine(containingUTF16Offset offset: Int, in textView: STTextView) {
        guard attachment?.isAttached(to: textView) == true else { return }
        attachment?.emitVisibleLine(containingUTF16Offset: offset)
    }

    func emitNavigationLine(
        containingUTF16Offset offset: Int,
        documentIdentity: EditorDocumentIdentity,
        in textView: STTextView
    ) {
        guard attachment?.isAttached(to: textView) == true else { return }
        attachment?.emitNavigationLine(
            containingUTF16Offset: offset,
            documentIdentity: documentIdentity
        )
    }

    func attach(to textView: STTextView) {
        if attachment?.isAttached(to: textView) == true {
            return
        }

        attachment?.detach()
        attachment = EditorScrollAttachment(textView: textView, proxy: self)
    }

    func detach() {
        attachment?.detach()
        attachment = nil
    }

    /// Full scans of the attached text view's shared line index; typing must not add any.
    var lineIndexRebuildCount: Int {
        attachment?.lineIndexRebuildCount ?? 0
    }
}

@MainActor
private final class EditorScrollAttachment {
    private weak var textView: STTextView?
    private weak var proxy: EditorScrollProxy?
    private var boundsObserver: NotificationObserver?
    /// Shared with the line-number gutter; the coordinator forwards native edits to it.
    private let lineIndexCache: EditorLineIndexCache
    private var lastEmittedLine: Int?

    var lineIndexRebuildCount: Int {
        lineIndexCache.rebuildCount
    }

    init(textView: STTextView, proxy: EditorScrollProxy) {
        self.textView = textView
        self.proxy = proxy
        lineIndexCache = EditorLineIndexCache.cache(for: textView)

        attachBoundsObserver(to: textView)
        emitVisibleLineIfNeeded()
    }

    func isAttached(to candidate: STTextView) -> Bool {
        textView === candidate
    }

    func detach() {
        boundsObserver = nil
    }

    func scrollToLine(_ line: Int) {
        guard let textView else { return }

        let offset = currentLineIndex().utf16Offset(forOneBasedLine: line)
        textView.scrollRangeToVisible(NSRange(location: offset, length: 0))
    }

    private func attachBoundsObserver(to textView: STTextView) {
        guard let clipView = textView.enclosingScrollView?.contentView else {
            return
        }

        clipView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationObserver(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.emitVisibleLineIfNeeded()
            }
        })
    }

    func emitVisibleLine(containingUTF16Offset offset: Int) {
        emitVisibleLineIfNeeded(currentLineIndex().oneBasedLine(containingUTF16Offset: offset))
    }

    func emitNavigationLine(
        containingUTF16Offset offset: Int,
        documentIdentity: EditorDocumentIdentity
    ) {
        let line = currentLineIndex().oneBasedLine(containingUTF16Offset: offset)
        // Forced navigation is never deduplicated against ordinary viewport reporting.
        // Updating the viewport receipt still prevents the ensuing bounds notification
        // from forwarding the same line a second time.
        lastEmittedLine = line
        proxy?.onScrollIntent?(.navigation(line: line, documentIdentity: documentIdentity))
    }

    private func emitVisibleLineIfNeeded() {
        guard let line = firstVisibleLine(), line != lastEmittedLine else { return }

        emitVisibleLineIfNeeded(line)
    }

    private func emitVisibleLineIfNeeded(_ line: Int) {
        guard line != lastEmittedLine else { return }

        lastEmittedLine = line
        proxy?.onScrollIntent?(.viewportChanged(line: line))
    }

    private func firstVisibleLine() -> Int? {
        guard let textView else { return nil }

        // Not `viewportRange.location`: the viewport extends above the visible area.
        let offset = EditorVisibleTop.utf16Offset(in: textView) ?? 0
        return currentLineIndex().oneBasedLine(containingUTF16Offset: offset)
    }

    private func currentLineIndex() -> EditorScrollLineIndex {
        lineIndexCache.currentIndex()
    }
}

private final class NotificationObserver {
    private let token: NSObjectProtocol

    init(_ token: NSObjectProtocol) {
        self.token = token
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}
