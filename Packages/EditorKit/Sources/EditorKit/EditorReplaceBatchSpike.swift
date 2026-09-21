import AppKit
import Foundation
import MarkdownCore
import STTextView

/// R0-only Replace All mechanism candidates (`docs/editor-replace-gates.md` §3.3).
///
/// Not a user-facing Replace API. App UI must not call this. `ranges` must be
/// left-to-right, non-overlapping, and inside the live source; otherwise the
/// spike refuses before writer activation or undo grouping.
enum EditorReplaceBatchMechanism: String {
    case reverseOrderedNativeEdits
    case minimalEnclosingRange
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
    /// Range validation and text construction belong to MarkdownCore's
    /// `EditorReplaceSourceConstruction`; the spike only chooses how to commit.
    static func plan(
        source: String,
        ranges: [NSRange],
        replacement: String,
        mechanism: EditorReplaceBatchMechanism
    ) -> EditorReplaceBatchPlan? {
        guard !ranges.isEmpty,
              let enclosing = EditorReplaceSourceConstruction.enclosingRange(of: ranges),
              let slice = EditorReplaceSourceConstruction.replacedSlice(
                  source,
                  enclosing: enclosing,
                  ranges: ranges,
                  replacement: replacement
              )
        else {
            return nil
        }

        switch mechanism {
        case .reverseOrderedNativeEdits:
            return .reverseOrderedNativeEdits
        case .minimalEnclosingRange:
            return .minimalEnclosingRange(range: enclosing, text: slice)
        case .fullDocument:
            guard let final = EditorReplaceSourceConstruction.replacedSource(
                source,
                ranges: ranges,
                replacement: replacement
            ) else {
                return nil
            }
            return .fullDocument(text: final)
        }
    }
}

enum EditorReplaceBatchPlan: Equatable {
    case reverseOrderedNativeEdits
    case minimalEnclosingRange(range: NSRange, text: String)
    case fullDocument(text: String)
}

@MainActor
extension MarkdownTextViewCoordinator {
    @discardableResult
    func performReplaceBatchSpike(
        _ request: EditorReplaceBatchRequest,
        using mechanism: EditorReplaceBatchMechanism,
        in textView: STTextView
    ) -> EditorReplaceBatchResult {
        let source = MarkdownTextView.textStorage(of: textView)?.string
            ?? textView.text
            ?? ""
        guard request.isAuthorized,
              let plan = EditorReplaceBatchSpike.plan(
                  source: source,
                  ranges: request.ranges,
                  replacement: request.replacement,
                  mechanism: mechanism
              )
        else {
            return EditorReplaceBatchResult(
                applied: false,
                mechanism: mechanism,
                nativeEditCount: 0
            )
        }

        var nativeEditCount = 0
        let applied = performPreflightedTextMutation(in: textView) {
            nativeEditCount = applyPreparedReplaceBatch(
                plan,
                request: request,
                sourceLength: (source as NSString).length,
                in: textView
            )
        }

        return EditorReplaceBatchResult(
            applied: applied && nativeEditCount > 0,
            mechanism: mechanism,
            nativeEditCount: nativeEditCount
        )
    }

    private func applyPreparedReplaceBatch(
        _ plan: EditorReplaceBatchPlan,
        request: EditorReplaceBatchRequest,
        sourceLength: Int,
        in textView: STTextView
    ) -> Int {
        textView.breakUndoCoalescing()
        let undoManager = textView.undoManager
        undoManager?.beginUndoGrouping()
        defer { undoManager?.endUndoGrouping() }
        let priorSelection = textView.selectedRange()
        // First so undo applies prior selection after STTextView restores text.
        undoManager?.registerUndo(withTarget: textView) { view in
            view.textSelection = priorSelection
        }

        var nativeEditCount = 0
        switch plan {
        case .reverseOrderedNativeEdits:
            for range in request.ranges.reversed() {
                insertAuthorizedText(
                    request.replacement,
                    replacementRange: range,
                    in: textView
                )
                nativeEditCount += 1
            }
        case let .minimalEnclosingRange(range, text):
            insertAuthorizedText(text, replacementRange: range, in: textView)
            nativeEditCount += 1
        case let .fullDocument(text):
            insertAuthorizedText(
                text,
                replacementRange: NSRange(location: 0, length: sourceLength),
                in: textView
            )
            nativeEditCount += 1
        }

        if let postSelection = request.postSelection {
            textView.textSelection = postSelection
            // Last so redo reapplies the planned caret after STTextView redo.
            undoManager?.registerUndo(withTarget: textView) { _ in
                undoManager?.registerUndo(withTarget: textView) { redoView in
                    redoView.textSelection = postSelection
                }
            }
        }
        return nativeEditCount
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
