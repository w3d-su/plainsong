import AppKit
import STTextView

/// Public scroll bridge for the app layer. It intentionally exposes source-line
/// concepts only, keeping STTextView and TextKit details inside EditorKit.
@MainActor
public final class EditorScrollProxy: ObservableObject {
    public var onVisibleLineChanged: ((Int) -> Void)?

    private var attachment: EditorScrollAttachment?

    public init() {}

    public func scrollToLine(_ line: Int) {
        attachment?.scrollToLine(line)
    }

    func emitVisibleLine(containingUTF16Offset offset: Int, in textView: STTextView) {
        guard attachment?.isAttached(to: textView) == true else { return }
        attachment?.emitVisibleLine(containingUTF16Offset: offset)
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
}

struct EditorScrollLineIndex {
    private let lineStarts: [Int]
    private let textUTF16Count: Int

    init(text: String) {
        var starts = [0]
        var offset = 0

        for unit in text.utf16 {
            offset += 1
            if unit == 10 {
                starts.append(offset)
            }
        }

        lineStarts = starts
        textUTF16Count = offset
    }

    func oneBasedLine(containingUTF16Offset offset: Int) -> Int {
        let clampedOffset = min(max(offset, 0), textUTF16Count)
        var lowerBound = 0
        var upperBound = lineStarts.count

        while lowerBound < upperBound {
            let midpoint = lowerBound + (upperBound - lowerBound) / 2
            if lineStarts[midpoint] <= clampedOffset {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }

        return max(1, lowerBound)
    }

    func utf16Offset(forOneBasedLine line: Int) -> Int {
        guard line > 1 else { return 0 }

        let index = line - 1
        guard lineStarts.indices.contains(index) else {
            return textUTF16Count
        }

        return lineStarts[index]
    }
}

@MainActor
private final class EditorScrollAttachment {
    private weak var textView: STTextView?
    private weak var proxy: EditorScrollProxy?
    private var boundsObserver: NotificationObserver?
    private var textObserver: NotificationObserver?
    private var lineIndex: EditorScrollLineIndex?
    private var lastEmittedLine: Int?

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
            Task { @MainActor [weak self] in
                self?.lineIndex = nil
            }
        })
    }

    func emitVisibleLine(containingUTF16Offset offset: Int) {
        emitVisibleLineIfNeeded(currentLineIndex().oneBasedLine(containingUTF16Offset: offset))
    }

    private func emitVisibleLineIfNeeded() {
        guard let line = firstVisibleLine(), line != lastEmittedLine else { return }

        emitVisibleLineIfNeeded(line)
    }

    private func emitVisibleLineIfNeeded(_ line: Int) {
        guard line != lastEmittedLine else { return }

        lastEmittedLine = line
        proxy?.onVisibleLineChanged?(line)
    }

    private func firstVisibleLine() -> Int? {
        guard let textView else { return nil }

        let layoutManager = textView.textLayoutManager
        let contentManager = textView.textContentManager
        let visibleLocation = layoutManager.textViewportLayoutController.viewportRange?.location
            ?? layoutManager.documentRange.location
        let offset = contentManager.offset(from: contentManager.documentRange.location, to: visibleLocation)
        guard offset != NSNotFound else { return nil }

        return currentLineIndex().oneBasedLine(containingUTF16Offset: offset)
    }

    private func currentLineIndex() -> EditorScrollLineIndex {
        if let lineIndex {
            return lineIndex
        }

        let text = textView.map { MarkdownTextView.textStorage(of: $0)?.string ?? $0.text ?? "" } ?? ""
        let newIndex = EditorScrollLineIndex(text: text)
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
