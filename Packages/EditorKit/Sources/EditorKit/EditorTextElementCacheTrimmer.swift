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
    /// UTF-16 length of requested trim ranges since creation (diagnostics and tests).
    private(set) var trimmedLength = 0
    /// Optional hosted-probe diagnostics; nil in ordinary editors. Events are schedule,
    /// start, trim, trimmed, refused, cancel, cancelled and complete. Ranges describe
    /// the captured viewport for task events or the requested chunk for trim events.
    var probeHandler: ((String, NSRange?) -> Void)?

    deinit {
        task?.cancel()
    }

    /// Restarts the settle delay; edits and scrolling report a new visible range first.
    func visibleRangeDidChange(_ visibleRange: NSRange, in textView: STTextView, canTrim: @escaping () -> Bool) {
        task?.cancel()
        probeHandler?("schedule", visibleRange)
        task = Task { [weak self, weak textView] in
            do {
                try await Task.sleep(nanoseconds: Self.settleNanoseconds)
                self?.probeHandler?("start", visibleRange)
                var end = textView.flatMap { MarkdownTextView.textStorage(of: $0)?.length } ?? 0
                while let textView, let range = Self.nextChunk(below: visibleRange, endingAt: end, in: textView) {
                    self?.probeHandler?("trim", range)
                    guard canTrim(),
                          let protectedRange = Self.protectedChunk(range, in: textView),
                          Self.trim(protectedRange, in: textView)
                    else {
                        self?.probeHandler?("refused", range)
                        return
                    }
                    self?.trimmedLength += protectedRange.length
                    self?.probeHandler?("trimmed", protectedRange)
                    end = protectedRange.location
                    // Let input and display run between chunks.
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
                self?.probeHandler?("complete", visibleRange)
            } catch {
                self?.probeHandler?("cancelled", visibleRange)
                return
            }
        }
    }

    func cancel() {
        probeHandler?("cancel", nil)
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

    /// Recheck native layout and selection immediately before each attribute edit, in
    /// the same main-actor turn. Keep the viewport prefix and the selected paragraphs
    /// with an 8192-character margin. An old offscreen caret does not protect all text
    /// before it: skip its protected interval and continue the descending pass above it.
    /// The returned range can precede the proposed range, so callers advance using its
    /// actual location. A missing or empty native viewport cannot admit a trim.
    static func protectedChunk(_ range: NSRange, in textView: STTextView) -> NSRange? {
        guard let textStorage = MarkdownTextView.textStorage(of: textView),
              let viewport = textView.textLayoutManager.textViewportLayoutController.viewportRange,
              !viewport.isEmpty
        else {
            return nil
        }
        let length = textStorage.length
        guard range.location >= 0,
              range.length > 0,
              range.location <= length,
              range.length <= length - range.location
        else {
            return nil
        }
        // The general visible-range helper falls back to the selection when TextKit
        // has no usable viewport. A trim cannot use that fallback as live geometry.
        let contentManager = textView.textContentManager
        let documentStart = contentManager.documentRange.location
        let viewportStart = contentManager.offset(from: documentStart, to: viewport.location)
        let viewportEnd = contentManager.offset(from: documentStart, to: viewport.endLocation)
        guard viewportStart != NSNotFound,
              viewportEnd != NSNotFound,
              viewportStart >= 0,
              viewportEnd > viewportStart,
              viewportEnd <= length
        else {
            return nil
        }
        let keepEnd = min(length, viewportEnd + max(viewportEnd - viewportStart, 8192))
        let end = NSMaxRange(range)
        guard end - keepEnd >= (end == length ? minimumTrimLength : 1) else { return nil }
        let start = max(range.location, end - chunkLength, keepEnd)
        let selection = textView.selectedRange()
        if selection.location != NSNotFound {
            guard selection.location >= 0,
                  selection.length >= 0,
                  selection.location <= length,
                  selection.length <= length - selection.location
            else {
                return nil
            }
            // Protect complete paragraphs, including text farther than 8192 from the
            // caret in a long paragraph. The selection can lead the native viewport.
            let paragraphs = textStorage.mutableString.paragraphRange(for: selection)
            let protectedStart = max(0, paragraphs.location - 8192)
            let protectedEnd = min(length, NSMaxRange(paragraphs) + 8192)
            if end > protectedEnd {
                let suffixStart = max(start, protectedEnd)
                return NSRange(location: suffixStart, length: end - suffixStart)
            }
            if end > protectedStart {
                // There is no suffix above the protected paragraphs. Jump over them
                // without stopping the pass; a later edit at the top stays cheap even
                // when the user left the old caret at the document end while reading.
                guard protectedStart > keepEnd else { return nil }
                let precedingStart = max(keepEnd, protectedStart - chunkLength)
                return NSRange(location: precedingStart, length: protectedStart - precedingStart)
            }
        }
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
