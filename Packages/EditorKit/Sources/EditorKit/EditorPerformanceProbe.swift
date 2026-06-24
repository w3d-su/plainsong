import AppKit
import Foundation
import MarkdownCore
import STTextView

@MainActor
enum EditorPerformanceProbe {
    struct TypingHotPathResult: Equatable {
        let iterations: Int
        let maxLatencyMilliseconds: Double
        let nativeInputMismatches: Int
    }

    struct VisibleRangeHighlightUpdateResult: Equatable {
        let elapsedMilliseconds: Double
        let highlightedRange: NSRange
        let didApplyHighlight: Bool
        let selectionAfterApply: NSRange
    }

    enum ProbeError: Error {
        case missingTextRange
        case missingTextView
    }

    static func measureTypingHotPath(
        fixtureText: String,
        fileKind: FileKind,
        replacementString: String,
        expectedNativeInput: Bool,
        iterations: Int,
        fixturePrefix: String = ""
    ) throws -> TypingHotPathResult {
        let textView = STTextView(frame: .zero)
        textView.text = fixturePrefix + fixtureText
        textView.textSelection = NSRange(location: 0, length: 0)

        guard let affectedRange = NSTextRange(textView.selectedRange(), in: textView.textContentManager) else {
            throw ProbeError.missingTextRange
        }

        let editingGuard = EditingBehaviorGuard()
        var maxLatencyMilliseconds = 0.0
        var nativeInputMismatches = 0

        for _ in 0 ..< iterations {
            let start = CFAbsoluteTimeGetCurrent()
            let shouldAllowNativeInput = EditingBehaviorsSupport.handleProposedChange(
                in: textView,
                affectedRange: affectedRange,
                replacementString: replacementString,
                fileKind: fileKind,
                editingGuard: editingGuard
            )
            maxLatencyMilliseconds = max(
                maxLatencyMilliseconds,
                (CFAbsoluteTimeGetCurrent() - start) * 1000
            )

            if shouldAllowNativeInput != expectedNativeInput {
                nativeInputMismatches += 1
            }
        }

        return TypingHotPathResult(
            iterations: iterations,
            maxLatencyMilliseconds: maxLatencyMilliseconds,
            nativeInputMismatches: nativeInputMismatches
        )
    }

    static func measureVisibleRangeHighlightUpdate(
        fixtureText: String,
        fileKind: FileKind,
        visibleRange: NSRange,
        editLocation: Int,
        insertion: String,
        highlightService: MarkdownHighlightService = MarkdownHighlightService()
    ) async throws -> VisibleRangeHighlightUpdateResult {
        let fixture = fixtureText as NSString
        let editRange = NSRange(location: editLocation, length: 0).clamped(toLength: fixture.length)
        let editedText = fixture.replacingCharacters(in: editRange, with: insertion)
        let selectedRange = NSRange(
            location: editRange.location + (insertion as NSString).length,
            length: 0
        ).clamped(toLength: (editedText as NSString).length)

        let scrollView = MarkdownSTTextView.scrollableTextView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        guard let textView = scrollView.documentView as? MarkdownSTTextView else {
            throw ProbeError.missingTextView
        }

        textView.frame = scrollView.bounds
        textView.text = editedText
        textView.textSelection = selectedRange
        scrollView.layoutSubtreeIfNeeded()

        let requestRange = visibleRange.clamped(toLength: (editedText as NSString).length)
        let start = DispatchTime.now().uptimeNanoseconds
        let highlighted = await highlightService.highlight(
            editedText,
            fileKind: fileKind,
            visibleRange: requestRange,
            theme: .standard,
            fontName: MarkdownSyntaxHighlighter.systemMonospacedFontName,
            fontSize: MarkdownSyntaxHighlighter.defaultFont.pointSize
        )

        let didApply = MarkdownTextView.applyHighlightedText(
            HighlightedText(revision: 1, range: highlighted.range, text: highlighted.text),
            to: textView
        )
        scrollView.displayIfNeeded()

        return VisibleRangeHighlightUpdateResult(
            elapsedMilliseconds: milliseconds(since: start),
            highlightedRange: highlighted.range,
            didApplyHighlight: didApply,
            selectionAfterApply: textView.selectedRange()
        )
    }

    static func paintEditor(text: String, frame: NSRect = NSRect(x: 0, y: 0, width: 1200, height: 800)) throws {
        let scrollView = MarkdownSTTextView.scrollableTextView()
        scrollView.frame = frame

        guard let textView = scrollView.documentView as? MarkdownSTTextView else {
            throw ProbeError.missingTextView
        }

        textView.frame = scrollView.bounds
        textView.text = text
        scrollView.layoutSubtreeIfNeeded()
        scrollView.displayIfNeeded()
    }

    private static func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }
}
