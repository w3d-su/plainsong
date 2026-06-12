import MarkdownCore
import SwiftUI

/// BlogEditor's source editor abstraction.
///
/// STTextView stays behind this view so App and lower layers never depend on concrete
/// editor library types. The typing hot path moves plain `String` only; styling is
/// debounced, computed off the main thread, and applied in place (agent.md §12).
@MainActor
public struct MarkdownEditorView: View {
    @Binding private var text: String
    @State private var styledText: HighlightedText?
    @State private var highlightRevision = 0
    @State private var selection: NSRange?

    private let fileKind: FileKind
    private let showsLineNumbers: Bool
    private let scrollProxy: EditorScrollProxy?

    public init(
        text: Binding<String>,
        fileKind: FileKind,
        showsLineNumbers: Bool = true,
        scrollProxy: EditorScrollProxy? = nil
    ) {
        _text = text
        self.fileKind = fileKind
        self.showsLineNumbers = showsLineNumbers
        self.scrollProxy = scrollProxy
    }

    public var body: some View {
        MarkdownTextView(
            // Proxy binding: typing no longer publishes through the document model
            // (DocumentSession.text is not @Published), so the editor schedules its
            // own highlight on every user edit here. `onChange(of: text)` below still
            // covers external replacements (file open), which do re-render this view.
            text: Binding(
                get: { text },
                set: { newValue in
                    text = newValue
                    scheduleHighlight()
                }
            ),
            styledText: styledText,
            selection: $selection,
            showsLineNumbers: showsLineNumbers,
            scrollProxy: scrollProxy
        )
        .onChange(of: text) { _, _ in
            scheduleHighlight()
        }
        .onChange(of: fileKind) { _, _ in
            scheduleHighlight()
        }
        .task(id: highlightRevision) {
            await applyDebouncedHighlight(for: highlightRevision)
        }
    }

    /// Every text or file-kind change bumps the revision; `.task(id:)` in `body`
    /// restarts, sleeps 300 ms, and only the latest revision computes. Scheduling
    /// during IME composition is safe because `MarkdownTextView` blocks the apply
    /// while marked text exists.
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

        let source = text
        let kind = fileKind
        let highlighted = await Task.detached(priority: .userInitiated) {
            MarkdownSyntaxHighlighter().highlight(source, fileKind: kind)
        }.value

        guard !Task.isCancelled, revision == highlightRevision else {
            return
        }

        styledText = HighlightedText(revision: revision, text: highlighted)
    }
}

extension MarkdownEditorView {
    /// Historical M1 regex bridge limit retained for regression tests and release notes.
    /// Parser-backed M1.5 highlighting runs off the main actor and does not skip large files.
    nonisolated static var maxComputedHighlightLength: Int {
        200_000
    }

    nonisolated static func shouldComputeHighlight(forLength length: Int) -> Bool {
        length >= 0
    }
}
