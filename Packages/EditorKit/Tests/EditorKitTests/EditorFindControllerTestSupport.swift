import AppKit
@testable import EditorKit
import STTextView
import SwiftUI
import XCTest

@MainActor
enum EditorFindControllerTestSupport {
    final class FindNavModel {
        var text: String
        var selection: NSRange?

        init(text: String, selection: NSRange?) {
            self.text = text
            self.selection = selection
        }
    }

    struct WindowedFixture {
        let window: NSWindow
        let scrollView: NSScrollView
        let textView: MarkdownSTTextView
        let coordinator: MarkdownTextViewCoordinator
    }

    static func makeWindowedFixture(
        model: FindNavModel,
        source: String,
        documentIdentity: EditorDocumentIdentity,
        height: CGFloat = 240
    ) throws -> WindowedFixture {
        let frame = NSRect(x: 0, y: 0, width: 560, height: height)
        let scrollView = MarkdownSTTextView.scrollableTextView(frame: frame)
        let textView = try XCTUnwrap(scrollView.documentView as? MarkdownSTTextView)
        textView.isEditable = true
        textView.isSelectable = true
        textView.showsLineNumbers = false
        textView.font = MarkdownSyntaxHighlighter.defaultFont
        // `MarkdownTextView.makeNSView` stamps this in production; the fixture builds the
        // scroll view directly, and the selection probes locate the editor by this identifier.
        textView.setAccessibilityIdentifier(EditorAccessibility.textViewIdentifier)
        textView.text = source
        textView.textSelection = NSRange(location: 0, length: 0)

        let textBinding = Binding(
            get: { model.text },
            set: { model.text = $0 }
        )
        let selectionBinding = Binding(
            get: { model.selection },
            set: { model.selection = $0 }
        )
        let coordinator = MarkdownTextViewCoordinator(
            text: textBinding,
            selection: selectionBinding
        )
        textView.textDelegate = coordinator
        coordinator.attachFocusHandler(to: textView)
        let candidate = coordinator.prepareDocumentTransition(
            text: textBinding,
            selection: selectionBinding,
            documentIdentity: documentIdentity,
            navigationCommand: nil,
            in: textView
        )
        coordinator.finishDocumentTransition(candidate, in: textView)

        let window = NSWindow(
            contentRect: scrollView.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        window.makeKeyAndOrderFront(nil)
        textView.layoutSubtreeIfNeeded()
        textView.textLayoutManager.ensureLayout(for: textView.textLayoutManager.documentRange)
        _ = window.makeFirstResponder(textView)
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))

        return WindowedFixture(
            window: window,
            scrollView: scrollView,
            textView: textView,
            coordinator: coordinator
        )
    }

    static func viewText(in textView: STTextView) -> String {
        MarkdownTextView.textStorage(of: textView)?.string ?? textView.text ?? ""
    }

    static func waitUntil(timeout: TimeInterval, predicate: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Condition not met within \(timeout)s")
    }
}
