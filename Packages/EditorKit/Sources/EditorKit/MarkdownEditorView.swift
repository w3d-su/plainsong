import MarkdownCore
import SwiftUI

/// BlogEditor's source editor abstraction.
///
/// STTextView stays behind this view so App and lower layers never depend on concrete
/// editor library types.
@MainActor
public struct MarkdownEditorView: View {
    @Binding private var text: String
    @State private var attributedText: AttributedString
    @State private var lastPlainText: String
    @State private var highlightRevision: Int
    @State private var selection: NSRange?

    private let fileKind: FileKind
    private let showsLineNumbers: Bool
    private let highlighter: MarkdownSyntaxHighlighter

    public init(
        text: Binding<String>,
        fileKind: FileKind,
        showsLineNumbers: Bool = true
    ) {
        let initialText = text.wrappedValue
        _text = text
        _attributedText = State(initialValue: AttributedString(initialText))
        _lastPlainText = State(initialValue: initialText)
        _highlightRevision = State(initialValue: 0)
        _selection = State(initialValue: nil)
        self.fileKind = fileKind
        self.showsLineNumbers = showsLineNumbers
        highlighter = MarkdownSyntaxHighlighter()
    }

    public var body: some View {
        MarkdownTextView(
            text: attributedTextBinding,
            selection: $selection,
            showsLineNumbers: showsLineNumbers
        )
        .onChange(of: text) { _, newValue in
            syncFromExternalText(newValue)
        }
        .onChange(of: fileKind) { _, _ in
            scheduleHighlight()
        }
        .task(id: highlightRevision) {
            await applyDebouncedHighlight(for: highlightRevision)
        }
    }

    private var attributedTextBinding: Binding<AttributedString> {
        Binding(
            get: { attributedText },
            set: { newValue in
                syncFromEditorText(newValue)
            }
        )
    }

    private func syncFromEditorText(_ newValue: AttributedString) {
        let plainText = String(newValue.characters)
        guard plainText != lastPlainText else { return }

        lastPlainText = plainText
        text = plainText
        attributedText = newValue
        scheduleHighlight()
    }

    private func syncFromExternalText(_ newValue: String) {
        guard newValue != lastPlainText else {
            return
        }

        lastPlainText = newValue
        attributedText = AttributedString(newValue)
        scheduleHighlight()
    }

    /// Every text or file-kind change bumps the revision; `.task(id:)` in `body`
    /// restarts, sleeps 300 ms, and only the latest revision applies. Scheduling
    /// during IME composition is safe because `MarkdownTextViewUpdatePolicy` blocks
    /// the apply while marked text exists.
    private func scheduleHighlight() {
        highlightRevision += 1
    }

    private func applyDebouncedHighlight(for revision: Int) async {
        do {
            try await Task.sleep(nanoseconds: 300_000_000)
        } catch {
            return
        }

        guard !Task.isCancelled, revision == highlightRevision else {
            return
        }

        guard Self.shouldComputeHighlight(forLength: lastPlainText.utf16.count) else {
            return
        }

        attributedText = highlighter.highlight(lastPlainText, fileKind: fileKind)
    }
}

extension MarkdownEditorView {
    /// Documents longer than this (UTF-16 units) skip computed styling: the M1 regex
    /// bridge re-styles the whole document synchronously, so very large files stay
    /// plain to protect typing latency (agent.md §12, M1 acceptance). M1.5's
    /// incremental tree-sitter highlighting removes this limit.
    nonisolated static var maxComputedHighlightLength: Int { 200_000 }

    nonisolated static func shouldComputeHighlight(forLength length: Int) -> Bool {
        length <= maxComputedHighlightLength
    }
}
