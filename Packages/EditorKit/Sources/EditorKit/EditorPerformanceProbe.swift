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
}
