import AppKit
import Foundation
import STTextView

/// R0-only Replace All mechanism candidates (`docs/editor-replace-gates.md` §3.3).
///
/// Not a user-facing Replace API. App UI must not call this.
enum EditorReplaceBatchMechanism: String {
    /// One writer activation, outer undo group, reverse-ordered native inserts.
    case reverseOrderedNativeEdits
    /// One native edit of the minimal enclosing raw range.
    case minimalEnclosingRange
    /// One full-document native replacement.
    case fullDocument
}

struct EditorReplaceBatchRequest {
    let ranges: [NSRange]
    let replacement: String
    let isAuthorized: Bool
    let postSelection: NSRange?

    init(
        ranges: [NSRange],
        replacement: String,
        isAuthorized: Bool = true,
        postSelection: NSRange? = nil
    ) {
        self.ranges = ranges
        self.replacement = replacement
        self.isAuthorized = isAuthorized
        self.postSelection = postSelection
    }
}

struct EditorReplaceBatchResult: Equatable {
    let applied: Bool
    let mechanism: EditorReplaceBatchMechanism
    let nativeEditCount: Int
}

enum EditorReplaceBatchSpike {
    static func enclosingRange(of ranges: [NSRange]) -> NSRange? {
        guard let first = ranges.first, let last = ranges.last else { return nil }
        let end = NSMaxRange(last)
        guard end >= first.location else { return nil }
        return NSRange(location: first.location, length: end - first.location)
    }

    static func replacedSource(
        _ source: String,
        ranges: [NSRange],
        replacement: String
    ) -> String? {
        let nsSource = source as NSString
        let length = nsSource.length
        var cursor = 0
        var parts: [String] = []
        parts.reserveCapacity(ranges.count * 2 + 1)
        for range in ranges {
            guard range.location >= cursor,
                  NSMaxRange(range) <= length
            else {
                return nil
            }
            if range.location > cursor {
                parts.append(nsSource.substring(with: NSRange(
                    location: cursor,
                    length: range.location - cursor
                )))
            }
            parts.append(replacement)
            cursor = NSMaxRange(range)
        }
        if cursor < length {
            parts.append(nsSource.substring(from: cursor))
        }
        return parts.joined()
    }
}

@MainActor
extension MarkdownTextViewCoordinator {
    @discardableResult
    func performReplaceBatchSpike(
        _ request: EditorReplaceBatchRequest,
        using mechanism: EditorReplaceBatchMechanism,
        in textView: STTextView
    ) -> EditorReplaceBatchResult {
        guard request.isAuthorized, !request.ranges.isEmpty else {
            return EditorReplaceBatchResult(
                applied: false,
                mechanism: mechanism,
                nativeEditCount: 0
            )
        }

        var nativeEditCount = 0
        let priorSelection = textView.selectedRange()
        let applied = performPreflightedTextMutation(in: textView) {
            textView.breakUndoCoalescing()
            let undoManager = textView.undoManager
            undoManager?.beginUndoGrouping()
            defer { undoManager?.endUndoGrouping() }
            // Register first so this runs last on undo, after STTextView restores
            // the replaced range, and can put the exact pre-batch selection back.
            undoManager?.registerUndo(withTarget: textView) { view in
                view.textSelection = priorSelection
            }

            switch mechanism {
            case .reverseOrderedNativeEdits:
                for range in request.ranges.reversed() {
                    insertAuthorizedText(
                        request.replacement,
                        replacementRange: range,
                        in: textView
                    )
                    nativeEditCount += 1
                }
            case .minimalEnclosingRange:
                guard let enclosing = EditorReplaceBatchSpike.enclosingRange(
                    of: request.ranges
                ) else {
                    return
                }
                let source = MarkdownTextView.textStorage(of: textView)?.string
                    ?? textView.text
                    ?? ""
                let nsSource = source as NSString
                guard NSMaxRange(enclosing) <= nsSource.length else { return }
                let localRanges = request.ranges.map { range in
                    NSRange(
                        location: range.location - enclosing.location,
                        length: range.length
                    )
                }
                let slice = nsSource.substring(with: enclosing)
                guard let newSlice = EditorReplaceBatchSpike.replacedSource(
                    slice,
                    ranges: localRanges,
                    replacement: request.replacement
                ) else {
                    return
                }
                insertAuthorizedText(newSlice, replacementRange: enclosing, in: textView)
                nativeEditCount += 1
            case .fullDocument:
                let source = MarkdownTextView.textStorage(of: textView)?.string
                    ?? textView.text
                    ?? ""
                guard let final = EditorReplaceBatchSpike.replacedSource(
                    source,
                    ranges: request.ranges,
                    replacement: request.replacement
                ) else {
                    return
                }
                let full = NSRange(location: 0, length: (source as NSString).length)
                insertAuthorizedText(final, replacementRange: full, in: textView)
                nativeEditCount += 1
            }

            if let postSelection = request.postSelection {
                textView.textSelection = postSelection
            }
        }

        return EditorReplaceBatchResult(
            applied: applied && nativeEditCount > 0,
            mechanism: mechanism,
            nativeEditCount: nativeEditCount
        )
    }

    private func insertAuthorizedText(
        _ string: String,
        replacementRange: NSRange,
        in textView: STTextView
    ) {
        editingBehaviorGuard.isApplying = true
        defer { editingBehaviorGuard.isApplying = false }
        textView.insertText(string, replacementRange: replacementRange)
    }
}
