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

    /// Native replacements arrive here before the content storage changes, so selection
    /// and layout callbacks inside the edit already see an index for the new text.
    func textWillChange(in range: NSRange, replacementString: String, in textView: STTextView) {
        guard attachment?.isAttached(to: textView) == true else { return }
        attachment?.textWillChange(in: range, replacementString: replacementString)
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

    /// Full line-index scans since attachment; typing must not add any.
    var lineIndexRebuildCount: Int {
        attachment?.lineIndexRebuildCount ?? 0
    }
}

@MainActor
private final class EditorScrollAttachment {
    private weak var textView: STTextView?
    private weak var proxy: EditorScrollProxy?
    private var boundsObserver: NotificationObserver?
    private var textObserver: NotificationObserver?
    private var lineIndex: EditorScrollLineIndex?
    /// Forwarded replacements whose `textDidChangeNotification` has not arrived yet.
    private var editsAwaitingDidChange = 0
    private var lastEmittedLine: Int?
    private(set) var lineIndexRebuildCount = 0

    init(textView: STTextView, proxy: EditorScrollProxy) {
        self.textView = textView
        self.proxy = proxy

        attachBoundsObserver(to: textView)
        attachTextObserver(to: textView)
        emitVisibleLineIfNeeded()
    }

    func isAttached(to candidate: STTextView) -> Bool {
        textView === candidate
    }

    func detach() {
        boundsObserver = nil
        textObserver = nil
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

    private func attachTextObserver(to textView: STTextView) {
        textObserver = NotificationObserver(NotificationCenter.default.addObserver(
            forName: STTextView.textDidChangeNotification,
            object: textView,
            queue: .main
        ) { [weak self] _ in
            // The observer is delivered on the main queue. A change that was not forwarded
            // through `textWillChange` invalidates here, before a same-turn source
            // installation can issue navigation into the new text.
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.editsAwaitingDidChange > 0 {
                    self.editsAwaitingDidChange -= 1
                } else {
                    self.lineIndex = nil
                }
            }
        })
    }

    func textWillChange(in range: NSRange, replacementString: String) {
        editsAwaitingDidChange += 1
        guard var index = lineIndex else { return }
        // Release the stored copy first so the edit mutates a uniquely referenced buffer.
        lineIndex = nil
        if index.replaceCharacters(in: range, with: replacementString) {
            lineIndex = index
        }
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
        // `mutableString` reads the storage in place, without bridging it to `String`.
        let text = textView.map { textView -> NSString in
            MarkdownTextView.textStorage(of: textView)?.mutableString
                ?? (textView.text ?? "") as NSString
        } ?? ""
        // The length check is O(1) and catches any edit that bypassed `textWillChange`.
        if let lineIndex, lineIndex.textUTF16Count == text.length {
            return lineIndex
        }

        let newIndex = EditorScrollLineIndex(utf16: text)
        lineIndexRebuildCount += 1
        lineIndex = newIndex
        return newIndex
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
