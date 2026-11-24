import Foundation
import MarkdownCore

/// Minimal UTF-16 diff that stays on surrogate and grapheme boundaries.
enum IOSAuthoringSourceDiff {
    static func edit(from old: String, to new: String, selection: NSRange) -> MarkdownEditResult? {
        if ExactSourceText.matches(old, new) {
            return nil
        }
        let oldText = old as NSString
        let newText = new as NSString
        guard let selectionEnd = checkedEnd(selection), selectionEnd <= oldText.length else {
            return nil
        }

        let rawPrefix = commonPrefixLength(oldText, newText)
        let prefix = floor(rawPrefix, in: old)
        var suffix = commonSuffixLength(oldText, newText, prefix: prefix)
        while suffix > 0 {
            let oldStart = oldText.length - suffix
            let newStart = newText.length - suffix
            let suffixFits = oldStart >= prefix && newStart >= prefix
            let aligned = isBoundary(oldStart, in: old) && isBoundary(newStart, in: new)
            if suffixFits, aligned {
                break
            }
            suffix -= 1
        }

        let oldMiddle = oldText.length - prefix - suffix
        let newMiddle = newText.length - prefix - suffix
        guard oldMiddle >= 0, newMiddle >= 0 else { return nil }
        if oldMiddle == 0, newMiddle == 0 {
            return nil
        }

        let replacementRange = NSRange(location: prefix, length: oldMiddle)
        let replacement = newText.substring(with: NSRange(location: prefix, length: newMiddle))
        guard let mapped = mapSelection(
            selection,
            replacement: replacementRange,
            newMiddleLength: newMiddle,
            newLength: newText.length
        ) else {
            return nil
        }
        return MarkdownEditResult(
            replacementRange: replacementRange,
            replacementString: replacement,
            newSelection: mapped
        )
    }

    static func mapSelection(
        _ selection: NSRange,
        replacement: NSRange,
        newMiddleLength: Int,
        newLength: Int
    ) -> NSRange? {
        guard let selectionEnd = checkedEnd(selection), let replacementEnd = checkedEnd(replacement) else {
            return nil
        }
        if selectionEnd <= replacement.location, selection.location < replacement.location {
            return fitted(selection, length: newLength)
        }
        if selection.location >= replacementEnd {
            let delta = newMiddleLength - replacement.length
            let (location, overflow) = selection.location.addingReportingOverflow(delta)
            guard !overflow, location >= 0 else { return nil }
            return fitted(NSRange(location: location, length: selection.length), length: newLength)
        }
        let (end, overflow) = replacement.location.addingReportingOverflow(newMiddleLength)
        guard !overflow else { return nil }
        return fitted(NSRange(location: end, length: 0), length: newLength)
    }

    private static func fitted(_ range: NSRange, length: Int) -> NSRange? {
        guard let end = checkedEnd(range), end <= length else { return nil }
        return range
    }

    private static func checkedEnd(_ range: NSRange) -> Int? {
        guard range.location >= 0, range.length >= 0 else { return nil }
        let (end, overflow) = range.location.addingReportingOverflow(range.length)
        return overflow ? nil : end
    }

    private static func commonPrefixLength(_ lhs: NSString, _ rhs: NSString) -> Int {
        let limit = min(lhs.length, rhs.length)
        var index = 0
        while index < limit, lhs.character(at: index) == rhs.character(at: index) {
            index += 1
        }
        return index
    }

    private static func commonSuffixLength(_ lhs: NSString, _ rhs: NSString, prefix: Int) -> Int {
        let limit = min(lhs.length - prefix, rhs.length - prefix)
        var suffix = 0
        while suffix < limit {
            let left = lhs.character(at: lhs.length - 1 - suffix)
            let right = rhs.character(at: rhs.length - 1 - suffix)
            if left != right {
                break
            }
            suffix += 1
        }
        return suffix
    }

    /// The start of the grapheme that contains UTF-16 `offset`. Only the grapheme at the
    /// offset is inspected: an array of every boundary cost 8 bytes per character of a
    /// document on the main actor for each frontmatter commit.
    static func floor(_ offset: Int, in text: String) -> Int {
        let units = text.utf16
        guard offset > 0 else { return 0 }
        guard let index = units.index(units.startIndex, offsetBy: offset, limitedBy: units.endIndex),
              index < units.endIndex
        else { return units.count }
        let start = text.index(before: text.index(after: index))
        return units.distance(from: units.startIndex, to: start)
    }

    private static func isBoundary(_ offset: Int, in text: String) -> Bool {
        floor(offset, in: text) == offset
    }
}
