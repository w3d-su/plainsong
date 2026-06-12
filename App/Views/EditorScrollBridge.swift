import AppKit
import PreviewKit
import SwiftUI

@MainActor
final class EditorScrollProxy: ObservableObject {
    weak var controller: EditorScrollControlling?

    func scrollToLine(_ line: Int) {
        controller?.scrollToLine(line)
    }
}

@MainActor
final class EditorPreviewScrollCoordinator: ObservableObject {
    let editorProxy = EditorScrollProxy()

    private weak var previewController: PreviewController?
    private var scrollOwner: ScrollOwner = .none
    private var decayTask: Task<Void, Never>?

    func connect(previewController: PreviewController) {
        self.previewController = previewController
    }

    func editorScrolled(to line: Int) {
        guard scrollOwner != .preview else { return }

        setScrollOwner(.editor)
        previewController?.scrollToLine(line, animated: false)
    }

    func previewScrolled(to line: Int) {
        guard scrollOwner != .editor else { return }

        setScrollOwner(.preview)
        editorProxy.scrollToLine(line)
    }

    private func setScrollOwner(_ owner: ScrollOwner) {
        scrollOwner = owner
        decayTask?.cancel()
        decayTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return
            }
            self?.scrollOwner = .none
        }
    }

    private enum ScrollOwner {
        case editor
        case preview
        case none
    }
}

@MainActor
protocol EditorScrollControlling: AnyObject {
    func scrollToLine(_ line: Int)
}

struct EditorScrollBridge: NSViewRepresentable {
    let proxy: EditorScrollProxy
    let onVisibleLineChanged: (Int) -> Void

    func makeNSView(context _: Context) -> BridgeView {
        let view = BridgeView()
        view.proxy = proxy
        view.onVisibleLineChanged = onVisibleLineChanged
        return view
    }

    func updateNSView(_ nsView: BridgeView, context _: Context) {
        nsView.proxy = proxy
        nsView.onVisibleLineChanged = onVisibleLineChanged
        nsView.attachIfPossible()
    }

    final class BridgeView: NSView, EditorScrollControlling {
        weak var proxy: EditorScrollProxy? {
            didSet {
                proxy?.controller = self
            }
        }

        var onVisibleLineChanged: ((Int) -> Void)?

        private weak var textView: NSTextView?
        private weak var scrollView: NSScrollView?
        private var boundsObserver: NSObjectProtocol?
        private var lastEmittedLine: Int?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attachIfPossible()
        }

        func attachIfPossible() {
            guard textView == nil, let root = window?.contentView else {
                return
            }

            guard let foundTextView = EditorScrollTextViewFinder.findTextView(in: root),
                  let foundScrollView = foundTextView.enclosingScrollView
            else {
                Task { @MainActor [weak self] in
                    await Task.yield()
                    self?.attachIfPossible()
                }
                return
            }

            textView = foundTextView
            scrollView = foundScrollView
            foundScrollView.contentView.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: foundScrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.emitVisibleLineIfNeeded()
                }
            }
            emitVisibleLineIfNeeded()
        }

        deinit {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
        }

        func scrollToLine(_ line: Int) {
            guard let textView else { return }

            let offset = Self.utf16Offset(forOneBasedLine: line, in: textView.string)
            textView.scrollRangeToVisible(NSRange(location: offset, length: 0))
        }

        private func emitVisibleLineIfNeeded() {
            guard let line = firstVisibleLine(), line != lastEmittedLine else { return }

            lastEmittedLine = line
            onVisibleLineChanged?(line)
        }

        private func firstVisibleLine() -> Int? {
            guard let textView, let scrollView else { return nil }

            if let layoutManager = textView.layoutManager, let textContainer = textView.textContainer {
                let visibleOrigin = scrollView.contentView.bounds.origin
                let containerOrigin = textView.textContainerOrigin
                let point = NSPoint(
                    x: max(0, visibleOrigin.x - containerOrigin.x),
                    y: max(0, visibleOrigin.y - containerOrigin.y)
                )
                let glyphIndex = layoutManager.glyphIndex(for: point, in: textContainer)
                let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
                return Self.oneBasedLine(containingUTF16Offset: characterIndex, in: textView.string)
            }

            let lineHeight = textView.font.map { ceil($0.ascender - $0.descender + $0.leading) } ?? 18
            return max(1, Int(scrollView.contentView.bounds.minY / lineHeight) + 1)
        }

        private static func oneBasedLine(containingUTF16Offset offset: Int, in text: String) -> Int {
            let safeOffset = min(max(offset, 0), text.utf16.count)
            var line = 1

            for scalar in text.utf16.prefix(safeOffset) where scalar == 10 {
                line += 1
            }

            return line
        }

        private static func utf16Offset(forOneBasedLine requestedLine: Int, in text: String) -> Int {
            guard requestedLine > 1 else { return 0 }

            var currentLine = 1
            var offset = 0

            for scalar in text.utf16 {
                if currentLine == requestedLine {
                    return offset
                }

                offset += 1
                if scalar == 10 {
                    currentLine += 1
                }
            }

            return offset
        }
    }
}

@MainActor
enum EditorScrollTextViewFinder {
    static func findTextView(in view: NSView) -> NSTextView? {
        if let scrollView = view as? NSScrollView {
            let textView = scrollView.documentView as? NSTextView
            if let textView, isSourceTextView(textView) {
                return textView
            }
        }

        if let textView = view as? NSTextView {
            return isSourceTextView(textView) ? textView : nil
        }

        for subview in view.subviews {
            if let textView = findTextView(in: subview) {
                return textView
            }
        }

        return nil
    }

    private static func isSourceTextView(_ textView: NSTextView) -> Bool {
        textView.isEditable
    }
}
