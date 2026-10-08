import Foundation
import MarkdownCore

enum IOSAuthoringLink {
    static func needsSheet(_ planned: MarkdownEditResult) -> Bool {
        let replacement = planned.replacementString
        return replacement == "[]()" || (replacement.hasPrefix("[") && replacement.hasSuffix("]()"))
    }

    static func collectsLabel(_ planned: MarkdownEditResult) -> Bool {
        planned.replacementString == "[]()"
    }

    static func submission(
        planned: MarkdownEditResult,
        label: String,
        url: String
    ) -> MarkdownEditResult? {
        if collectsLabel(planned) {
            if label.isEmpty, url.isEmpty {
                return planned
            }
            guard planned.replacementString == "[]()" else { return nil }
            return replaced(planned, replacement: "[\(label)](\(url))")
        }
        if url.isEmpty {
            return planned
        }
        let storage = planned.replacementString as NSString
        let caret = planned.newSelection.location - planned.replacementRange.location
        guard planned.newSelection.length == 0, caret >= 0, caret <= storage.length else {
            return nil
        }
        let spliced = storage.substring(to: caret) + url + storage.substring(from: caret)
        return replaced(planned, replacement: spliced)
    }

    private static func replaced(
        _ planned: MarkdownEditResult,
        replacement: String
    ) -> MarkdownEditResult? {
        let length = (replacement as NSString).length
        let (end, overflow) = planned.replacementRange.location.addingReportingOverflow(length)
        guard !overflow, end >= 0 else { return nil }
        return MarkdownEditResult(
            replacementRange: planned.replacementRange,
            replacementString: replacement,
            newSelection: NSRange(location: end, length: 0)
        )
    }
}
