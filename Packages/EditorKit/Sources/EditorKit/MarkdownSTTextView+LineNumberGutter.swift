import AppKit
import STTextView

extension MarkdownSTTextView {
    private static let lineNumberGutterPluginID = STPluginIdentifier("app.plainsong.lineNumberGutter")

    /// Shows the line-number gutter with `style`, or hides it for `nil`.
    ///
    /// Needs the `EditorScrollView` from `scrollableTextView(frame:)`, which tiles the
    /// gutter beside its clip view. Showing or hiding it changes the text width once, like
    /// any window resize.
    func setLineNumberGutterStyle(_ style: EditorLineNumberGutterView.Style?) {
        if showsLineNumbers {
            // STTextView's gutter costs 9-16 ms per layout pass in large documents.
            showsLineNumbers = false
        }
        guard let style else {
            removeLineNumberGutter()
            return
        }
        if let lineNumberGutter {
            lineNumberGutter.update(style: style)
            return
        }
        guard let scrollView = enclosingScrollView as? EditorScrollView, scrollView.documentView === self else {
            return
        }

        let gutter = EditorLineNumberGutterView(textView: self, scrollView: scrollView, style: style)
        lineNumberGutter = gutter
        scrollView.lineNumberGutter = gutter
        addPlugin(LineNumberGutterLayoutPlugin(gutter: gutter), id: Self.lineNumberGutterPluginID)
    }

    private func removeLineNumberGutter() {
        guard let gutter = lineNumberGutter else { return }
        removePlugin(Self.lineNumberGutterPluginID)
        gutter.detach()
        lineNumberGutter = nil
        if let scrollView = enclosingScrollView as? EditorScrollView, scrollView.lineNumberGutter === gutter {
            scrollView.lineNumberGutter = nil
        }
    }
}

/// STTextView reports each converged viewport layout once, including layouts TextKit's
/// viewport controller runs on its own.
private struct LineNumberGutterLayoutPlugin: STPlugin {
    weak var gutter: EditorLineNumberGutterView?

    func setUp(context: any Context) {
        context.events.onDidLayoutViewport { [weak gutter] _ in
            gutter?.textViewDidLayoutViewport()
        }
    }
}
