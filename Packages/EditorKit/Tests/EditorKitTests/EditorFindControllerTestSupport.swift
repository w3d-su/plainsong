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

    /// Every window registered through `registerWindowForTeardown(_:)` — this file's fixture
    /// plus the test classes' own factories — is held until `tearDownWindows()` runs.
    ///
    /// A shown key window carrying an editor first responder stays in
    /// `NSApplication.shared.windows` after the local variable goes away, where it can still
    /// answer responder-chain questions for later tests.
    private static var fixtureWindows: [NSWindow] = []

    /// Creates the fixture's window and registers it for teardown.
    private static func makeRegisteredWindow(hosting scrollView: NSScrollView) -> NSWindow {
        let window = NSWindow(
            contentRect: scrollView.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        registerWindowForTeardown(window)
        return window
    }

    /// Registers a test window so `tearDownWindows()` will hide it and drop this reference.
    ///
    /// An ordered-in window owned by a find-fixture test class must go through here when that
    /// class relies on `tearDownWindows()`. This includes windows built by the class's own
    /// fixture factory; otherwise its shared teardown is a no-op that only reads like cleanup.
    @discardableResult
    static func registerWindowForTeardown(_ window: NSWindow) -> NSWindow {
        // `orderOut`, not `close`: a programmatic NSWindow defaults to release-on-close, and
        // closing it would over-release a window the test still holds.
        window.isReleasedWhenClosed = false
        fixtureWindows.append(window)
        return window
    }

    /// Hides every registered window and drops the registry's references. Call from `tearDown()`.
    ///
    /// `orderOut` alone leaves the window in `NSApplication.shared.windows` (verified) — it
    /// stops being visible and stops being key, which is what removes it from responder-chain
    /// reach. It leaves that list only once the last reference goes away, which is why the
    /// registry releases rather than merely hiding.
    static func tearDownWindows() {
        for window in fixtureWindows {
            window.orderOut(nil)
        }
        fixtureWindows.removeAll()
    }

    /// Builds a windowed editor fixture.
    ///
    /// The window is registered for teardown. Registration only records it — nothing is
    /// hidden until the test class's `tearDown()` calls `tearDownWindows()`, so a single test
    /// may hold several fixture windows at once.
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

        let window = makeRegisteredWindow(hosting: scrollView)
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
