import AppKit
import STTextView

/// Releases TextKit 2's cached text elements below the viewport once scrolling settles.
///
/// `NSTextContentStorage` keeps every paragraph element the viewport has ever laid out,
/// and each character edit rewrites the range of every cached element after the edit.
/// After the end of a 1 MiB document had been in view, typing above it cost ~50 ms per
/// keystroke in release builds, against ~0.3 ms in a freshly opened document. An
/// attribute-only edit notification makes the content storage drop the elements in a
/// range without changing characters, attributes, selection or Undo; it costs time only
/// for elements that are actually cached (~0.1 ms for an uncached 500 K tail).
@MainActor
final class EditorTextElementCacheTrimmer {
    static let settleNanoseconds: UInt64 = 400_000_000
    /// Keeps chunks under ~10 ms when the whole tail is cached (measured ~9.6 ms per 64 K).
    static let chunkLength = 32768
    /// Below this much text past the viewport, rewriting cached ranges stays cheap.
    static let minimumTrimLength = 32768

    private var task: Task<Void, Never>?
    /// Characters released since creation (diagnostics and tests).
    private(set) var trimmedLength = 0

    deinit {
        task?.cancel()
    }

    /// Restarts the settle delay; edits and scrolling report a new visible range first.
    func visibleRangeDidChange(_ visibleRange: NSRange, in textView: STTextView, canTrim: @escaping () -> Bool) {
        task?.cancel()
        task = Task { [weak self, weak textView] in
            do {
                try await Task.sleep(nanoseconds: Self.settleNanoseconds)
                var end = textView.flatMap { MarkdownTextView.textStorage(of: $0)?.length } ?? 0
                while let textView, let range = Self.nextChunk(below: visibleRange, endingAt: end, in: textView) {
                    guard canTrim(), Self.trim(range, in: textView) else { return }
                    self?.trimmedLength += range.length
                    end = range.location
                    // Let input and display run between chunks.
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
            } catch {
                return
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// The next range to release, walking back from `end` to a margin below the viewport.
    static func nextChunk(below visibleRange: NSRange, endingAt end: Int, in textView: STTextView) -> NSRange? {
        guard let length = MarkdownTextView.textStorage(of: textView)?.length,
              visibleRange.location != NSNotFound
        else {
            return nil
        }
        // TextKit prefetches below the visible area; keep that and a little more warm.
        let keepEnd = min(length, NSMaxRange(visibleRange) + max(visibleRange.length, 8192))
        let end = min(end, length)
        guard end - keepEnd >= (end == length ? minimumTrimLength : 1) else {
            return nil
        }
        let start = max(keepEnd, end - chunkLength)
        return NSRange(location: start, length: end - start)
    }

    @discardableResult
    static func trim(_ range: NSRange, in textView: STTextView) -> Bool {
        guard !textView.hasMarkedText(),
              let textStorage = MarkdownTextView.textStorage(of: textView),
              textStorage.editedMask.isEmpty,
              NSMaxRange(range) <= textStorage.length
        else {
            return false
        }
        textStorage.beginEditing()
        textStorage.edited(.editedAttributes, range: range, changeInLength: 0)
        textStorage.endEditing()
        return true
    }
}
