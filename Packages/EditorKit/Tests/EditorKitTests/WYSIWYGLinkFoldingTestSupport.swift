import AppKit
@testable import EditorKit
import MarkdownCore
import STTextView
import XCTest

@MainActor
struct AppliedLinkPresentation {
    let textView: MarkdownSTTextView
    let textStorage: NSTextStorage
    let presentation: MarkdownHighlightResult
}

@MainActor
func linkPresentation(
    _ source: String,
    selection: NSRange,
    revision: Int = 1
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

@MainActor
@discardableResult
func applyLinkPresentation(
    _ source: String,
    selection: NSRange,
    revision: Int,
    to textView: STTextView
) -> Bool {
    MarkdownTextView.applyHighlightedText(
        linkPresentation(source, selection: selection, revision: revision),
        to: textView
    )
}

@MainActor
func applyLinkPresentation(_ source: String, selection: NSRange) throws -> AppliedLinkPresentation {
    let textView = MarkdownSTTextView(frame: .zero)
    textView.font = MarkdownSyntaxHighlighter.defaultFont
    textView.text = source
    textView.textSelection = selection
    XCTAssertTrue(textView.setWYSIWYGZeroWidthFoldingEnabled(true))

    let presentation = MarkdownSyntaxHighlighter().highlight(
        source,
        fileKind: .markdown,
        visibleRange: NSRange(location: 0, length: (source as NSString).length),
        developmentPresentation: .inlineFoldRevealWithLinkFolding,
        selection: selection
    )
    XCTAssertTrue(MarkdownTextView.applyHighlightedText(
        HighlightedText(
            revision: 1,
            range: presentation.range,
            text: presentation.text,
            foldPlan: presentation.foldPlan
        ),
        to: textView
    ))

    return try AppliedLinkPresentation(
        textView: textView,
        textStorage: XCTUnwrap(MarkdownTextView.textStorage(of: textView)),
        presentation: presentation
    )
}
