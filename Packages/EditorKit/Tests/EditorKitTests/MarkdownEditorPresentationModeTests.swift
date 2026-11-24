import AppKit
@testable import EditorKit
import SwiftUI
import XCTest

/// Switching the WYSIWYG mode must request a highlight of its own. Nothing else changes
/// with it, so the folds would otherwise wait for the next edit or scroll.
@MainActor
final class MarkdownEditorPresentationModeTests: XCTestCase {
    func testSwitchingPresentationModeFoldsAndUnfoldsWithoutAnEdit() async throws {
        let model = Model()
        let hostingView = NSHostingView(rootView: Host(model: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        defer { window.close() }

        let textView = try await waitFor("the editor is installed") {
            Self.textView(in: hostingView)
        }
        try await waitFor("the source highlight is applied") {
            Self.hasSyntaxColor(in: textView) ? true : nil
        }
        XCTAssertFalse(Self.hasFoldedDelimiter(in: textView))

        model.presentation = .inlineFoldRevealWithLinkFolding
        try await waitFor("entering WYSIWYG folds the delimiters") {
            Self.hasFoldedDelimiter(in: textView) ? true : nil
        }

        model.presentation = .source
        try await waitFor("leaving WYSIWYG reveals the delimiters") {
            Self.hasFoldedDelimiter(in: textView) ? nil : true
        }
    }

    private final class Model: ObservableObject {
        @Published var text = "plain line\n\nsome **bold** words\n"
        @Published var presentation: MarkdownEditorDevelopmentPresentation = .source
    }

    private struct Host: View {
        @ObservedObject var model: Model

        var body: some View {
            MarkdownEditorView(
                text: $model.text,
                fileKind: .markdown,
                _developmentPresentation: model.presentation
            )
        }
    }

    @discardableResult
    private func waitFor<Value>(
        _ description: String,
        _ probe: () -> Value?
    ) async throws -> Value {
        for _ in 0 ..< 200 {
            if let value = probe() {
                return value
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out waiting until \(description)")
        throw CancellationError()
    }

    private static func textView(in view: NSView) -> MarkdownSTTextView? {
        if let textView = view as? MarkdownSTTextView {
            return textView
        }
        for subview in view.subviews {
            if let textView = textView(in: subview) {
                return textView
            }
        }
        return nil
    }

    private static func hasFoldedDelimiter(in textView: MarkdownSTTextView) -> Bool {
        hasAttribute(WYSIWYGInlineFoldPresentation.foldedDelimiterAttribute, in: textView)
    }

    private static func hasSyntaxColor(in textView: MarkdownSTTextView) -> Bool {
        hasAttribute(.foregroundColor, in: textView)
    }

    private static func hasAttribute(_ key: NSAttributedString.Key, in textView: MarkdownSTTextView) -> Bool {
        guard let storage = MarkdownTextView.textStorage(of: textView) else {
            return false
        }
        var found = false
        storage.enumerateAttribute(key, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            if value != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }
}
