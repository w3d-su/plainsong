import AppKit
@testable import EditorKit

/// Editor work around a measured phase: separates the gutter's own cost from the rest, and
/// records the TextKit element-cache state typing started from.
@MainActor
struct EditorProbeCounters {
    let gutterDraws: Int
    let gutterDrawMilliseconds: Double
    let gutterWidthChanges: Int
    let lineIndexRebuilds: Int
    /// Characters `EditorTextElementCacheTrimmer` has released so far.
    let trimmedLength: Int
    let editorHeight: CGFloat

    init(_ editor: MarkdownSTTextView) {
        gutterDraws = editor.lineNumberGutter?.drawCount ?? 0
        gutterDrawMilliseconds = editor.lineNumberGutter?.totalDrawMilliseconds ?? 0
        gutterWidthChanges = editor.lineNumberGutter?.thicknessChangeCount ?? 0
        lineIndexRebuilds = editor.lineIndexCache.rebuildCount
        trimmedLength = (editor.textDelegate as? MarkdownTextViewCoordinator)?.textElementCacheTrimmer
            .trimmedLength ?? 0
        editorHeight = editor.frame.height
    }

    func report(since start: Self) -> [String: Any] {
        [
            "gutterDraws": gutterDraws - start.gutterDraws,
            "gutterDrawMilliseconds": gutterDrawMilliseconds - start.gutterDrawMilliseconds,
            "gutterWidthChanges": gutterWidthChanges - start.gutterWidthChanges,
            "lineIndexRebuilds": lineIndexRebuilds - start.lineIndexRebuilds,
            "trimmedBeforeTyping": start.trimmedLength,
            "trimmedAfterTyping": trimmedLength,
            "trimmedDuringTyping": trimmedLength - start.trimmedLength,
            "editorHeightBeforeTyping": start.editorHeight,
        ]
    }
}

/// Reads existing geometry only; no layout, display or element walk is forced.
@MainActor
struct TypingProbeGeometry {
    let report: [String: Double]

    init(_ editor: MarkdownSTTextView) {
        let viewport = MarkdownTextView.visibleTextRange(of: editor)
        report = [
            "textContainerWidth": editor.textContainer.size.width,
            "editorWidth": editor.frame.width,
            "editorHeight": editor.frame.height,
            "windowContentWidth": Double(editor.window?.contentView?.bounds.width ?? 0),
            "clipWidth": Double(editor.enclosingScrollView?.contentView.bounds.width ?? 0),
            "clipHeight": Double(editor.enclosingScrollView?.contentView.bounds.height ?? 0),
            "visibleY": editor.visibleRect.origin.y,
            "viewportLocation": Double(viewport?.location ?? NSNotFound),
            "viewportLength": Double(viewport?.length ?? 0),
        ]
    }

    static func extrema(_ samples: [Self], minimum: Bool) -> [String: Double] {
        var result: [String: Double] = [:]
        for sample in samples {
            for (key, value) in sample.report {
                guard let previous = result[key] else {
                    result[key] = value
                    continue
                }
                result[key] = minimum ? min(previous, value) : max(previous, value)
            }
        }
        return result
    }
}
