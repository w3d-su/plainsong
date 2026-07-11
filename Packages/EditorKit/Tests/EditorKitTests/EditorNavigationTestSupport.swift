@testable import EditorKit
import Foundation

@MainActor
func editorNavigationWYSIWYGPresentation(
    _ source: String,
    selection: NSRange,
    revision: Int
) -> HighlightedText {
    let highlighted = MarkdownSyntaxHighlighter().highlight(
        source,
        fileKind: .markdown,
        visibleRange: NSRange(location: 0, length: (source as NSString).length),
        developmentPresentation: .inlineFoldRevealWithLinkFolding,
        selection: selection
    )
    return HighlightedText(
        revision: revision,
        range: highlighted.range,
        text: highlighted.text,
        foldPlan: highlighted.foldPlan
    )
}
