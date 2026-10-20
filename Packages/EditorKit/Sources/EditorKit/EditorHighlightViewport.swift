import Combine
import Foundation

/// Viewport observation is deliberately not published: scrolling inside the prepared
/// window must not rebuild the SwiftUI editor or restart its parser. Content/settings
/// changes still start a fresh revision unconditionally through the existing scheduler.
@MainActor
final class EditorHighlightViewport: ObservableObject {
    private(set) var visibleRange: NSRange?
    private(set) var requestedRange: NSRange?

    func update(_ range: NSRange) -> Bool {
        guard Self.isValid(range), range.length > 0, range != visibleRange else { return false }
        visibleRange = range
        guard let requestedRange else { return true }
        return range.location < requestedRange.location || NSMaxRange(range) > NSMaxRange(requestedRange)
    }

    func beginRequest(selection: NSRange?) {
        requestedRange = MarkdownEditorView.highlightRequestRange(visibleRange: visibleRange, selection: selection)
    }

    func didComplete(range: NSRange) {
        requestedRange = range
    }

    nonisolated static func padded(_ range: NSRange) -> NSRange {
        guard isValid(range) else { return NSRange(location: 0, length: 0) }
        let padding = max(1024, min(4096, range.length / 2))
        let start = max(0, range.location - padding)
        let end = NSMaxRange(range)
        let paddedEnd = end + min(padding, Int.max - end)
        return NSRange(location: start, length: paddedEnd - start)
    }

    private nonisolated static func isValid(_ range: NSRange) -> Bool {
        range.location != NSNotFound && range.location >= 0 && range.length >= 0
            && range.location <= Int.max - range.length
    }
}
